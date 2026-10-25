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
    }

    private var controls: some View {
        let plan = state.convertPlan
        let marked = plan.selectedItems.count
        return HStack(spacing: 14) {
            Button("Add Files or Folders…") {
                state.addToConvert(urls: Panels.chooseFiles(message: "Choose wavetable files (.wav, .flac, .wt, .pgdata) or folders to search"))
            }
            .keyboardShortcut("o")
            Button("Clean Up Names…") { showNameCleanup = true }
                .disabled(plan.items.allSatisfy { $0.factorySlot != nil })
                .help("Propose tidier names for the tables listed (e.g., slot numbers removed, title case), used for the converted files. Factory wavetables keep their names.")
                .sheet(isPresented: $showNameCleanup) { NameCleanupSheet(state: state, page: .convert) }
            Spacer()
            Button("Remove Selected") { state.removeConvertItems(selection); selection = [] }.disabled(selection.isEmpty)
                .help("Remove the selected tables from this list (the files are not touched)")
            Button("Remove All…") { state.removeAllConvert(); if state.convertPlan.items.isEmpty { selection = [] } }
                .disabled(plan.items.isEmpty)
                .help("Remove every table from this page (the files are not touched)")
            // Always shown, so the toolbar keeps its width; available for the 3rd Wave presets.
            Button("Send to Pack…") { state.convertTables(sendToPack: true) }
                .disabled(marked == 0 || !plan.preset.isThirdWave)
                .help(plan.preset.isThirdWave
                      ? "Convert the tables marked to convert into .wt files in a folder you choose, then add them to the Pack page"
                      : "Available when converting to a 3rd Wave table")
            Button("Convert…") { state.convertTables() }
                .disabled(marked == 0)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)
                .help("Convert the tables marked to convert into a folder you choose")
        }
        .padding(10)
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
        VStack(alignment: .leading, spacing: 0) {
            ConvertSummaryStrip(state: st)
            ConvertTable(state: st, items: shown, selection: $selection)
        }
    }
}

/// One line above the table: how many tables there are and how many are marked to convert,
/// what blocks any of them, and the filter for the blocked ones.
struct ConvertSummaryStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        let plan = state.convertPlan
        let total = plan.items.count
        let marked = plan.selectedItems.count
        HStack(spacing: 12) {
            Text("\(total) table\(total == 1 ? "" : "s") · \(marked) to convert")
                .monospacedDigit()
            ConvertBlockedCount(count: plan.needsFrameSizeCount, one: "needs a frame size", many: "need frame sizes",
                                help: "Tables marked to convert whose file doesn't say how long each wave is: choose a size in the Input column")
            ConvertBlockedCount(count: plan.cannotSplitCount, one: "can't be split", many: "can't be split",
                                help: "Tables marked to convert whose samples don't divide into frames of the size given")
            Spacer()
            Toggle("Show only tables that can't be converted yet", isOn: $state.convertOnlyAttention)
                .toggleStyle(.checkbox).font(.caption)
                .disabled(plan.blockedCount == 0)
                .help(plan.blockedCount == 0
                      ? "Every table marked to convert can be converted"
                      : "Show only the tables marked to convert that still need a frame size, or whose samples don't divide into frames")
        }
        .frame(height: 28)
        .padding(.horizontal, 12)
    }
}

/// "1 needs a frame size" or "3 can't be split" in red, or nothing when the count is 0. `one` and
/// `many` complete the count for one table and for several.
struct ConvertBlockedCount: View {
    let count: Int
    let one: String
    let many: String
    let help: String

    var body: some View {
        if count > 0 {
            Label("\(count) \(count == 1 ? one : many)", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .help(help)
        }
    }
}

/// The table itself: whether it is converted, its state, its name (editable) and origin, its
/// size and where that came from, what the destination writes, and what changes on the way.
struct ConvertTable: View {
    @ObservedObject var state: AppState
    let items: [ConvertPlan.Item]
    @Binding var selection: Set<UUID>

    var body: some View {
        let st = state
        let plan = st.convertPlan
        Table(items, selection: $selection) {
            TableColumn("Convert") { (item: ConvertPlan.Item) in ConvertCheckCell(state: st, item: item) }
                .width(44)
            TableColumn("") { (item: ConvertPlan.Item) in ConvertStatusCell(status: plan.status(item), tip: plan.statusDescription(item)) }
                .width(22)
            TableColumn("Name") { (item: ConvertPlan.Item) in ConvertNameCell(state: st, item: item, selection: $selection) }
                .width(min: 140, ideal: 260)
            // Input and Output are both frames × samples per frame: the headers say the unit (a
            // Table header takes no tooltip on macOS 13), the cells spell it out on hover. The
            // widths fit the headers and the longest cells ("256 × 2,048  from markers" with its
            // chevron; "256 → 64 frames, picked evenly, turned down" on two lines).
            TableColumn("Input (frames × samples)") { (item: ConvertPlan.Item) in ConvertFrameSizeCell(state: st, item: item, selection: $selection) }
                .width(min: 210, ideal: 250)
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
        .visibleScrollers()
        .onDeleteCommand { state.removeConvertItems(selection); selection = [] }
    }
}

struct ConvertCheckCell: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    var body: some View {
        Toggle("", isOn: Binding(get: { state.convertPlan.isSelected(item) },
                                 set: { state.convertPlan.setSelected(item.id, $0) }))
            .labelsHidden()
            .help(item.factorySlot != nil && state.convertPlan.preset.isThirdWave
                  ? "Your 3rd Wave is expected to have this factory table (U48–U55 since the 2025 update, which Groove Synthesis offers as a download), so it starts unchecked" : "")
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
        case .cannotSplit:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(tip)
        case .ready:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help(tip)
        case .excluded:
            Text("").help(tip)
        }
    }
}

/// The table's name, editable in place, with its badges: where it came from when that matters
/// (a slot in a .pgdata, a 3rd Wave or Surge .wt, a FLAC), a factory table, and identical
/// copies found elsewhere.
struct ConvertNameCell: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    @Binding var selection: Set<UUID>
    var body: some View {
        let plan = state.convertPlan
        let included = plan.isSelected(item)
        HStack(spacing: 5) {
            ConvertNameField(state: state, item: item, included: included, selection: $selection)
            if let origin = item.originBadge {
                ConvertBadge(text: origin, tip: item.location.url.path)
            }
            if let slot = item.factorySlot {
                ConvertBadge(text: "Factory",
                             tip: "Same as factory \(slot.label)\(item.factoryName.map { " " + $0 } ?? "")")
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

/// The name as plain text that becomes a field when clicked. Return commits, Escape or leaving
/// the field without a change restores the name; an empty name is not taken. Editing selects
/// the row, so the preview below shows the table being renamed.
struct ConvertNameField: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    let included: Bool
    @Binding var selection: Set<UUID>
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .foregroundStyle(included ? Color.primary : Color.secondary)
            .focused($focused)
            .onAppear { text = item.name }
            .onChange(of: item.name) { (name: String) in if !focused { text = name } }
            .onSubmit { commit() }
            .onExitCommand { text = item.name; focused = false }
            .onChange(of: focused) { (now: Bool) in
                if now { selection = [item.id] } else { commit() }
            }
            .help(item.newName == nil ? "The table's name; click to edit it. The name goes on the converted file (and inside a 3rd Wave table); the source file is not changed."
                                      : "Was \u{201C}\(item.table.name)\u{201D}; click to edit")
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { text = item.name; return }
        if trimmed != item.name { state.convertPlan.rename(item.id, to: trimmed) }
        text = trimmed
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
/// comes from ("in the file", "guessed", "set manually"; `Item.sizeQualifier`). When the file
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
            Label("Can't split", systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(1)
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
                  ? "The file doesn't say how long each wave is. Click to choose one of the sizes its length allows (frames × samples per frame)."
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
        HStack(spacing: 4) {
            Text("\(count)").fontWeight(countWeight)
                .frame(minWidth: Self.countWidth, alignment: .trailing)
            Text("×").foregroundStyle(.secondary)
            Text(ConvertPlan.formatCount(size)).fontWeight(sizeWeight)
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// The size chooser: what a frame size is and how to judge one, what the file says, a button
/// per size the file allows with the first wave drawn at that size, and which size the
/// samples suggest (see `FrameSizeFit`), marked "likely" but never applied by itself.
struct ConvertSizePopover: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    private var fitLine: String? {
        switch item.frameSizeFit {
        case .likely(let n):
            return "The samples suggest \(ConvertPlan.formatCount(n)): frames of that size are alike from one to the next, as a wavetable's are. A suggestion, not a certainty."
        case .tie:
            return "The sizes fit the samples equally well; nothing here settles it."
        case .unclear:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Frame size").font(.headline)
            Text("The frame size says where each wave starts and ends; a wrong size cuts every wave in the wrong place. The right size usually shows one complete cycle that joins at both ends; a size that is too large repeats it, too small cuts it off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.basisDescription)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            // Three buttons to a row, each wide enough for its result on two lines; a length
            // that allows more sizes (up to six) gets a second row rather than narrower buttons.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 144, maximum: 150), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 8) {
                ForEach(item.frameSizeChoices, id: \.self) { (size: Int) in
                    ConvertSizeButton(state: state, item: item, size: size,
                                      likely: FrameSizeFit.likelySize(item.frameSizeFit) == size)
                }
            }
            if let fitLine {
                Text(fitLine)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 480, alignment: .leading)
    }
}

/// One size: the first wave cut at that size, "64 × 128" under it, what the destination makes
/// of it ("→ 64 × 1,024, 4 → 64 frames, repeated"), and "likely" when the samples suggest it.
struct ConvertSizeButton: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    let size: Int
    var likely: Bool = false

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
                WaveThumbnail(samples: Array(item.table.samples.prefix(size)), tint: chosen ? Color.accentColor : Color.primary)
                Text("\(frames) × \(ConvertPlan.formatCount(size))")
                    .font(.caption).monospacedDigit().lineLimit(1)
                    .foregroundStyle(chosen ? Color.accentColor : Color.primary)
                // The result wraps under the size rather than being cut off: "→ 64 × 1,024,"
                // then "4 → 64 frames, repeated".
                Text(becomes)
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if likely {
                    Text("likely").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)   // the grid's column (see ConvertSizePopover)
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
