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

/// The Convert page: the wavetables found in the files added (top left), how the selected one
/// will be converted (bottom left), and the destination with its options (right). The decisions
/// are in `ConvertPlan`; the detail pane is in ConvertDetail.swift and the destination pane in
/// ConvertDestination.swift.
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
                          detail: "Add WAV wavetables (Serum, Vital, and others), 3rd Wave .wt and .pgdata files, and Surge .wt files; folders work too, and files without wavetables are passed over. Each table then shows its frames, its frame size, and how that was decided. Convert converts existing wavetables between formats; it does not make wavetables from other audio.")
            } else {
                HSplitView {
                    VSplitView {
                        ConvertTablesPane(selection: $selection)
                            .frame(minWidth: 520, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                        ConvertDetailPane(selection: selection)
                            .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 180, maxHeight: .infinity)
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
        let ticked = plan.selectedItems.count
        return HStack(spacing: 14) {
            Button("Add Files or Folders…") {
                state.addToConvert(urls: Panels.chooseFiles(message: "Choose wavetable files (.wav, .wt, .pgdata) or folders to search"))
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
                .disabled(ticked == 0 || !plan.preset.isThirdWave)
                .help(plan.preset.isThirdWave
                      ? "Convert the ticked tables to .wt files in a folder you choose, then add them to the Pack page"
                      : "Available when converting to a 3rd Wave table")
            Button("Convert…") { state.convertTables() }
                .disabled(ticked == 0)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)
                .help("Convert the ticked tables into a folder you choose")
        }
        .padding(10)
    }
}

// MARK: - The tables found

struct ConvertTablesPane: View {
    @EnvironmentObject var state: AppState
    @Binding var selection: Set<UUID>

    /// The rows shown: every table, or only those needing attention.
    private var shown: [ConvertPlan.Item] {
        let plan = state.convertPlan
        return state.convertOnlyAttention ? plan.items.filter(plan.needsAttention) : plan.items
    }

    var body: some View {
        let st = state
        VStack(alignment: .leading, spacing: 0) {
            ConvertSummaryStrip(state: st)
            ConvertTable(state: st, items: shown, selection: $selection)
                .overlay {
                    if shown.isEmpty {
                        ListPlaceholder(text: "No tables need attention.")
                    }
                }
        }
    }
}

/// One line above the table: how many tables there are and are ticked, what blocks any of
/// them, and the filter for tables needing attention.
struct ConvertSummaryStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        let plan = state.convertPlan
        let total = plan.items.count
        HStack(spacing: 12) {
            Text("\(total) table\(total == 1 ? "" : "s") · \(plan.selectedItems.count) ticked")
                .monospacedDigit()
            ConvertBlockedCount(count: plan.needsFrameSizeCount, what: "a frame size", plural: "frame sizes")
            ConvertBlockedCount(count: plan.cannotSplitCount, what: "splitting", plural: "splitting")
            Spacer()
            Toggle("Only tables needing attention", isOn: $state.convertOnlyAttention)
                .toggleStyle(.checkbox).font(.caption)
                .help("Tables that can't convert yet, whose frame size is guessed, or that carry a warning")
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
                      ? "Ticked tables whose samples don't divide into frames of the size given"
                      : "Ticked tables whose file doesn't say how long each wave is: choose a size in the Size column")
        }
    }
}

/// The table itself: whether it is converted, its state, what it is, its size and where that
/// came from, what it becomes, and whether there are notes.
struct ConvertTable: View {
    @ObservedObject var state: AppState
    let items: [ConvertPlan.Item]
    @Binding var selection: Set<UUID>

    var body: some View {
        let st = state
        let plan = st.convertPlan
        Table(items, selection: $selection) {
            TableColumn("Convert") { (item: ConvertPlan.Item) in ConvertTickCell(state: st, item: item) }
                .width(44)
            TableColumn("") { (item: ConvertPlan.Item) in ConvertStatusCell(status: plan.status(item), tip: plan.statusDescription(item)) }
                .width(22)
            TableColumn("Name") { (item: ConvertPlan.Item) in ConvertNameCell(state: st, item: item) }
                .width(min: 120, ideal: 240)
            TableColumn("Source") { (item: ConvertPlan.Item) in ConvertSourceCell(item: item, ticked: plan.isSelected(item)) }
                .width(min: 80, ideal: 130)
            TableColumn("Size") { (item: ConvertPlan.Item) in ConvertFrameSizeCell(state: st, item: item) }
                .width(min: 100, ideal: 120)
            TableColumn("Size from") { (item: ConvertPlan.Item) in ConvertSizeFromCell(item: item, ticked: plan.isSelected(item)) }
                .width(min: 90, ideal: 120)
            TableColumn("Becomes") { (item: ConvertPlan.Item) in
                ConvertBecomesCell(expected: plan.expected(for: item), summary: plan.expectedResult(for: item), ticked: plan.isSelected(item))
            }
                .width(min: 150, ideal: 220)
            TableColumn("") { (item: ConvertPlan.Item) in ConvertNotesCell(notes: plan.itemNotes(for: item)) }
                .width(24)
        }
        .visibleScrollers()
        .onDeleteCommand { state.removeConvertItems(selection); selection = [] }
    }
}

struct ConvertTickCell: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    var body: some View {
        Toggle("", isOn: Binding(get: { state.convertPlan.isSelected(item) },
                                 set: { state.convertPlan.setSelected(item.id, $0) }))
            .labelsHidden()
            .help(item.factorySlot != nil && state.convertPlan.preset.isThirdWave
                  ? "Every 3rd Wave already has this factory table, so it starts unticked" : "")
    }
}

/// Red when the table can't convert yet, a grey check when it is ready, nothing when unticked.
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
        case .unticked:
            Text("").help(tip)
        }
    }
}

/// The kind of source; the file's path (and those of identical copies) on hover.
struct ConvertSourceCell: View {
    let item: ConvertPlan.Item
    let ticked: Bool
    var body: some View {
        Text(item.sourceDescription).lineLimit(1)
            .foregroundStyle(ticked ? Color.primary : Color.secondary)
            .help(([item.location.url.path] + item.alsoIn.map { "Also: " + $0.url.path }).joined(separator: "\n"))
    }
}

/// The table's name with its badges: a factory table, identical copies found elsewhere, and, for a
/// 3rd Wave destination, a name its name fields cannot hold as it is.
struct ConvertNameCell: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    var body: some View {
        let plan = state.convertPlan
        let ticked = plan.isSelected(item)
        HStack(spacing: 5) {
            Text(item.name).lineLimit(1).help(item.name)
                .foregroundStyle(ticked ? Color.primary : Color.secondary)
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
            if plan.preset.isThirdWave { ThirdWaveNameNote(name: item.name) }
        }
    }
}

/// For a 3rd Wave destination: a scissors icon when the `.wt` will carry a different name (cut to
/// 31 characters, accents outside Latin-1 removed, other characters as "?"), the name on hover.
struct ThirdWaveNameNote: View {
    let name: String
    /// The icon alone (the table), or with the name it is written as (the Clean Up Names sheet).
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

/// Frames × size. When the file leaves the frame size open, a bordered menu in red asking for
/// one; when only its length suggested the size, a menu of the sizes its length allows.
struct ConvertFrameSizeCell: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    private func title(_ size: Int) -> String {
        "\(item.table.samples.count / max(size, 1)) × \(ConvertPlan.formatCount(size))"
    }

    var body: some View {
        let choices = item.frameSizeChoices
        let ticked = state.convertPlan.isSelected(item)
        if choices.isEmpty && !item.needsFrameSize {
            Text(item.sizeDescription).monospacedDigit().lineLimit(1)
                .foregroundStyle(ticked ? Color.primary : Color.secondary)
                .help(item.sizeDescription + " (frames × samples per frame)")
        } else if choices.isEmpty {
            Label("Can't split", systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(1)
                .help(state.convertPlan.statusDescription(item))
        } else {
            Menu {
                ForEach(choices, id: \.self) { (size: Int) in
                    Button { state.convertPlan.chooseFrameSize(item.id, size) } label: {
                        if size == item.frameSize { Label(title(size), systemImage: "checkmark") }
                        else { Text(title(size)) }
                    }
                }
            } label: {
                ConvertSizeMenuLabel(text: item.frameSize.map { title($0) } ?? "Choose size…", needed: item.frameSize == nil)
            }
            // A bordered pop-up with its chevron, so it reads as a menu rather than as text.
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.visible)
            .help(item.needsFrameSize
                  ? "The file doesn't say how long each wave is. Choose one of the sizes its length allows (frames × samples per frame); the pane below shows what each looks like."
                  : "Only the file's length suggested this frame size. Choose another if it sounds wrong (frames × samples per frame).")
        }
    }
}

/// The closed menu's label: red while a size is still needed.
struct ConvertSizeMenuLabel: View {
    let text: String
    let needed: Bool
    var body: some View {
        Text(text).monospacedDigit().lineLimit(1)
            .foregroundStyle(needed ? Color.red : Color.primary)
    }
}

/// An icon and a word for what the frame size rests on; the whole story on hover.
struct ConvertSizeFromCell: View {
    let item: ConvertPlan.Item
    let ticked: Bool

    private var symbol: String {
        switch item.sizeSource {
        case .inFile: return "doc.text"
        case .fileName: return "textformat"
        case .sidecar: return "doc.plaintext"
        case .markers: return "flag"
        case .guessed: return "questionmark.circle"
        case .notStated: return "exclamationmark.octagon.fill"
        case .yourChoice: return "hand.point.up.left"
        }
    }

    private var tint: Color {
        switch item.sizeSource {
        case .notStated: return .red
        case .guessed: return .secondary
        default: return ticked ? Color.primary : Color.secondary
        }
    }

    private var word: Text {
        let t = Text(item.sizeSource.label)
        return item.sizeSource == .guessed ? t.italic() : t
    }

    var body: some View {
        Label {
            word
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .help(item.basisDescription)
    }
}

/// "→ 64 × 1,024" with the numbers that change in semibold, then small icons for each change
/// (frame size, frame count, turned down to fit), each explained on hover. "—" when blocked.
struct ConvertBecomesCell: View {
    let expected: ConvertPlan.ExpectedResult?
    let summary: String
    let ticked: Bool

    var body: some View {
        if let e = expected {
            HStack(spacing: 6) {
                sizeText(e)
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(ticked ? Color.primary : Color.secondary)
                ConvertChangeIcons(expected: e)
            }
            .help(ticked ? summary : "Not ticked. If ticked: " + summary)
        } else {
            Text("—").foregroundStyle(.secondary).help(summary)
        }
    }

    private func sizeText(_ e: ConvertPlan.ExpectedResult) -> Text {
        let countChanged = e.frameCountOut != e.frameCountIn
        let count = Text("\(e.frameCountOut)").fontWeight(countChanged ? .semibold : .regular)
        let size = Text(ConvertPlan.formatCount(e.frameSizeOut)).fontWeight(e.resizes ? .semibold : .regular)
        let arrow = Text("→ ")
        let times = Text(" × ")
        return arrow + count + times + size
    }
}

/// The small icons after the size: resized, fewer or more frames, turned down to fit.
struct ConvertChangeIcons: View {
    let expected: ConvertPlan.ExpectedResult

    var body: some View {
        let e = expected
        HStack(spacing: 4) {
            if e.resizes {
                Image(systemName: "arrow.left.and.right")
                    .help("Resized from \(ConvertPlan.formatCount(e.frameSizeIn)) samples per frame")
            }
            if let grows = e.frameCountGrows {
                Image(systemName: grows ? "plus.circle" : "minus.circle")
                    .help("\(ConvertPlan.formatCount(e.frameCountIn)) → \(e.tableFrameCount) frames, " + ConvertPlan.policyPhrase(e.countPolicy))
            }
            if e.scaledToFit {
                Image(systemName: "speaker.wave.1")
                    .help("Turned down to fit: peak \(String(format: "%.2f", Double(e.peak)))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// An icon when there are notes: a triangle for warnings, else an information circle. All the
/// notes on hover.
struct ConvertNotesCell: View {
    let notes: ConvertPlan.ItemNotes
    var body: some View {
        if notes.isEmpty {
            Text("")
        } else if notes.warnings.isEmpty {
            Image(systemName: "info.circle").foregroundStyle(.secondary).help(notes.all.joined(separator: "\n"))
        } else {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(notes.all.joined(separator: "\n"))
        }
    }
}
