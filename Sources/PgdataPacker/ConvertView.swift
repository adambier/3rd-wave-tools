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

/// The Convert page: the wavetables found in the files added (top left), a read-only preview of
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
                          detail: "Add WAV and FLAC wavetables (Serum, Vital, and others), 3rd Wave .wt and .pgdata files, and Surge .wt files; folders work too, and files without wavetables are passed over. Each table then shows its frames, its frame size, and what converting changes. Convert converts existing wavetables between formats; it does not make wavetables from other audio.")
            } else {
                HSplitView {
                    VSplitView {
                        ConvertTablesPane(selection: $selection)
                            .frame(minWidth: 520, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                        ConvertDetailPane(selection: selection)
                            .frame(maxWidth: .infinity, minHeight: 170, idealHeight: 300, maxHeight: .infinity)
                    }
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

// MARK: - The tables found

struct ConvertTablesPane: View {
    @EnvironmentObject var state: AppState
    @Binding var selection: Set<UUID>

    /// The rows shown: every table, or only those that cannot convert yet.
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
            ConvertBlockedCount(count: plan.needsFrameSizeCount, what: "a frame size", plural: "frame sizes")
            ConvertBlockedCount(count: plan.cannotSplitCount, what: "splitting", plural: "splitting")
            Spacer()
            Toggle("Only tables that can't convert yet", isOn: $state.convertOnlyAttention)
                .toggleStyle(.checkbox).font(.caption)
                .disabled(plan.blockedCount == 0)
                .help(plan.blockedCount == 0
                      ? "Every table marked to convert can convert"
                      : "Show only the tables marked to convert that still need a frame size, or whose samples don't divide into frames")
        }
        .frame(height: 28)
        .padding(.horizontal, 12)
    }
}

/// "1 needs a frame size" in red, or nothing when the count is 0.
struct ConvertBlockedCount: View {
    let count: Int
    let what: String
    let plural: String

    var body: some View {
        if count > 0 {
            let text = count == 1 ? "1 needs \(what)" : "\(count) need \(plural)"
            Label(text, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .help(what == "splitting"
                      ? "Tables marked to convert whose samples don't divide into frames of the size given"
                      : "Tables marked to convert whose file doesn't say how long each wave is: choose a size in the Size column")
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
                .width(min: 140, ideal: 280)
            // Input and Output are both frames × samples per frame (the cells say so on hover;
            // a Table header takes no tooltip on macOS 13).
            TableColumn("Input") { (item: ConvertPlan.Item) in ConvertFrameSizeCell(state: st, item: item, selection: $selection) }
                .width(min: 130, ideal: 170)
            TableColumn("Output") { (item: ConvertPlan.Item) in
                ConvertOutputCell(expected: plan.expected(for: item), summary: plan.expectedResult(for: item), included: plan.isSelected(item))
            }
                .width(min: 100, ideal: 140)
            TableColumn("Changes") { (item: ConvertPlan.Item) in
                ConvertChangesCell(words: plan.changeWords(for: item), summary: plan.expectedResult(for: item),
                                   notes: plan.itemNotes(for: item), included: plan.isSelected(item))
            }
                .width(min: 160, ideal: 270)
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
                  ? "Every 3rd Wave already has this factory table, so it starts unchecked" : "")
    }
}

/// Red when the table can't convert yet, a grey check when it is ready, nothing when it is not
/// marked to convert.
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

/// The input as frames × samples per frame, with a word after it when the size is not stated
/// in the file ("guessed", "set manually", "markers"). When the file allows other sizes, the
/// cell is a button that opens the size chooser and selects the row, so the preview below
/// shows the table; when the size is still open, it is red.
struct ConvertFrameSizeCell: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    @Binding var selection: Set<UUID>
    @State private var choosing = false

    var body: some View {
        let included = state.convertPlan.isSelected(item)
        let choices = item.frameSizeChoices
        if choices.isEmpty && !item.needsFrameSize {
            ConvertSizeText(item: item, included: included)
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

/// "64 × 2,048" and, in secondary type, the qualifier when there is one.
struct ConvertSizeText: View {
    let item: ConvertPlan.Item
    let included: Bool
    var body: some View {
        HStack(spacing: 5) {
            Text(item.sizeDescription).monospacedDigit().lineLimit(1)
                .foregroundStyle(included ? Color.primary : Color.secondary)
            if let word = item.sizeQualifier {
                Text(word).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
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
            Text("A wavetable file is one long run of samples; the frame size says where each wave starts and ends. If it's wrong, every wave is cut in the wrong place. The right size usually shows one complete cycle that joins up at both ends. A size that is too large shows the cycle repeated; one that is too small shows part of it. If in doubt, check the result in the destination synth.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.basisDescription)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
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
        .frame(width: 380, alignment: .leading)
    }
}

/// One size: the first wave cut at that size, "64 × 128" under it, and "likely" under that
/// when the samples suggest this size.
struct ConvertSizeButton: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    let size: Int
    var likely: Bool = false

    var body: some View {
        let chosen = item.frameSize == size
        let frames = item.table.samples.count / max(size, 1)
        Button { state.convertPlan.chooseFrameSize(item.id, size) } label: {
            VStack(spacing: 3) {
                WaveThumbnail(samples: Array(item.table.samples.prefix(size)), tint: chosen ? Color.accentColor : Color.primary)
                Text("\(frames) × \(ConvertPlan.formatCount(size))")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(chosen ? Color.accentColor : Color.primary)
                if likely {
                    Text("likely").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chosen ? Color.accentColor : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(chosen ? "The frame size used: \(frames) frames of \(ConvertPlan.formatCount(size)) samples"
                     : "Use \(ConvertPlan.formatCount(size)) samples per frame (\(frames) frames)")
    }
}

/// What the destination writes: "64 × 1,024", the numbers that change in semibold; "—" when
/// the table cannot convert.
struct ConvertOutputCell: View {
    let expected: ConvertPlan.ExpectedResult?
    let summary: String
    let included: Bool

    var body: some View {
        if let e = expected {
            sizeText(e)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(included ? Color.primary : Color.secondary)
                .help("Output (frames × samples per frame): " + (included ? summary : "not marked to convert. If it were: " + summary))
        } else {
            Text("—").foregroundStyle(.secondary).help(summary)
        }
    }

    private func sizeText(_ e: ConvertPlan.ExpectedResult) -> Text {
        let countChanged = e.frameCountOut != e.frameCountIn
        let count = Text("\(e.frameCountOut)").fontWeight(countChanged ? .semibold : .regular)
        let size = Text(ConvertPlan.formatCount(e.frameSizeOut)).fontWeight(e.resizes ? .semibold : .regular)
        let times = Text(" × ")
        return count + times + size
    }
}

/// What converting changes, in a few words each ("resized, 64 → 256 frames"), then the
/// warnings in orange ("peak 1.14"); "—" when only the format changes. The whole story on hover.
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
                line(words).lineLimit(1).help(tip)
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

/// For a 3rd Wave destination: a scissors icon when the `.wt` will carry a different name (cut to
/// 31 characters, accents outside Latin-1 removed, other characters as "?"), the name on hover;
/// with `compact` off (the Clean Up Names sheet), the name itself.
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
