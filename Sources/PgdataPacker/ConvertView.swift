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

/// The Convert page: wavetables found in the files added (left), and the destination with its
/// options (right). The decisions are in `ConvertPlan`.
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
                          detail: "Add wavetable files or folders: WAV wavetables (Serum, Vital, and others), 3rd Wave .wt and .pgdata files, and Surge .wt files. Folders are searched, and files without wavetables are passed over. Convert converts existing wavetables between formats; it does not make wavetables from other audio, which is what the 3rd Wave's Wave Maker does.")
            } else {
                HSplitView {
                    ConvertTablesPane(selection: $selection)
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    ConvertDestinationPane()
                        .frame(minWidth: 280, idealWidth: 330, maxWidth: 440, maxHeight: .infinity)
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

    var body: some View {
        let st = state
        let plan = st.convertPlan
        VStack(alignment: .leading, spacing: 4) {
            Text("Wavetables found").font(.headline).padding(.horizontal, 12).padding(.top, 8)
            Text("Converts existing wavetables between formats; it does not make wavetables from other audio (that is the 3rd Wave's Wave Maker). Identical tables are listed once.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            // Most important first: whether it is converted, what it is, and its size.
            Table(plan.items, selection: $selection) {
                TableColumn("Convert") { (item: ConvertPlan.Item) in ConvertTickCell(state: st, item: item) }
                    .width(52)
                TableColumn("Name") { (item: ConvertPlan.Item) in ConvertNameCell(state: st, item: item) }
                    .width(min: 120, ideal: 190)
                TableColumn("Source") { (item: ConvertPlan.Item) in ConvertSourceCell(item: item) }
                    .width(min: 110, ideal: 170)
                TableColumn("Frames") { (item: ConvertPlan.Item) in ConvertFrameSizeCell(state: st, item: item) }
                    .width(min: 110, ideal: 130)
                TableColumn("Frame size from") { (item: ConvertPlan.Item) in
                    Text(item.basisDescription).foregroundStyle(.secondary).lineLimit(1).help(item.basisDescription)
                }
                    .width(min: 100, ideal: 150)
                TableColumn("Interpolation") { (item: ConvertPlan.Item) in
                    Text(item.interpolationDescription).foregroundStyle(.secondary).lineLimit(1)
                }
                    .width(min: 70, ideal: 90)
                TableColumn("Result") { (item: ConvertPlan.Item) in
                    ConvertResultCell(text: plan.expectedResult(for: item), ticked: plan.isSelected(item))
                }
                    .width(min: 160, ideal: 260)
                TableColumn("Notes") { (item: ConvertPlan.Item) in
                    ConvertNotesCell(notes: plan.notes(for: item), waiting: item.needsFrameSize && item.chosenFrameSize == nil)
                }
                    .width(min: 160, ideal: 280)
            }
            .visibleScrollers()
            .onDeleteCommand { state.removeConvertItems(selection); selection = [] }
        }
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

/// The kind of source; the file's path (and those of identical copies) on hover.
struct ConvertSourceCell: View {
    let item: ConvertPlan.Item
    var body: some View {
        Text(item.sourceDescription).lineLimit(1)
            .help(([item.location.url.path] + item.alsoIn.map { "Also: " + $0.url.path }).joined(separator: "\n"))
    }
}

/// What converting the table is expected to produce; grey when it is not ticked.
struct ConvertResultCell: View {
    let text: String
    let ticked: Bool
    var body: some View {
        Text(text).lineLimit(1)
            .foregroundStyle(ticked ? Color.primary : Color.secondary)
            .help(ticked ? text : "Not ticked. If ticked: " + text)
    }
}

/// The table's name with its badges: a factory table, identical copies found elsewhere, and, for a
/// 3rd Wave destination, a name its name fields cannot hold as it is.
struct ConvertNameCell: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    var body: some View {
        HStack(spacing: 4) {
            Text(item.name).lineLimit(1).help(item.name)
            if let slot = item.factorySlot {
                ConvertBadge(text: "Factory \(slot.label)",
                             tip: "Identical to the 3rd Wave's \(item.factoryLabel ?? slot.label)")
            }
            if let also = item.alsoInDescription {
                ConvertBadge(text: item.alsoIn.count == 1 ? "1 copy" : "\(item.alsoIn.count) copies",
                             tip: "The same table is " + also + "; it is listed and converted once.")
            }
            if state.convertPlan.preset.isThirdWave { ThirdWaveNameNote(name: item.name) }
        }
    }
}

/// For a 3rd Wave destination: the name the `.wt` will carry, when it differs from the table's
/// (cut to 31 characters, accents outside Latin-1 removed, other characters as "?").
struct ThirdWaveNameNote: View {
    let name: String
    var body: some View {
        let written = WavetableWriter.thirdWaveName(name)
        if written.name != name.trimmingCharacters(in: .whitespaces) {
            Label("Written as \u{201C}\(written.name)\u{201D}", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).lineLimit(1)
                .help(written.notes.joined(separator: "\n"))
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

/// Frames × size. When the file leaves the frame size open, or only its length suggested one, a
/// menu of the sizes its length allows.
struct ConvertFrameSizeCell: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    private func title(_ size: Int) -> String {
        "\(item.table.samples.count / max(size, 1)) × \(ConvertPlan.formatCount(size))"
    }

    var body: some View {
        let choices = item.frameSizeChoices
        if choices.isEmpty && !item.needsFrameSize {
            Text(item.sizeDescription).monospacedDigit().lineLimit(1)
        } else if choices.isEmpty {
            Label("Size unknown", systemImage: "xmark.octagon").foregroundStyle(.red).lineLimit(1)
                .help("The file does not settle the frame size, and its length allows none of the usual sizes.")
        } else {
            Menu {
                ForEach(choices, id: \.self) { size in
                    Button { state.convertPlan.chooseFrameSize(item.id, size) } label: {
                        if size == item.frameSize { Label(title(size), systemImage: "checkmark") }
                        else { Text(title(size)) }
                    }
                }
            } label: {
                Text(item.frameSize.map { title($0) } ?? "Choose size…").monospacedDigit().lineLimit(1)
            }
            // A bordered pop-up with its chevron, so it reads as a menu rather than as text.
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.visible)
            .help(item.needsFrameSize
                  ? "The file does not settle the frame size: choose one of the sizes its length allows (frames × samples per frame)."
                  : "Only the file's length suggested this frame size: choose another if it is wrong (frames × samples per frame).")
        }
    }
}

/// The first note, with the rest on hover.
struct ConvertNotesCell: View {
    let notes: [String]
    /// The table still needs a frame size: shown as a warning.
    let waiting: Bool
    var body: some View {
        if notes.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            let text = notes[0] + (notes.count > 1 ? " (+\(notes.count - 1) more)" : "")
            Label(text, systemImage: waiting ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(waiting ? Color.orange : Color.secondary)
                .lineLimit(1)
                .help(notes.joined(separator: "\n"))
        }
    }
}

// MARK: - Destination

struct ConvertDestinationPane: View {
    @EnvironmentObject var state: AppState
    @State private var showAdvanced = false

    var body: some View {
        let plan = state.convertPlan
        let ticked = plan.selectedItems
        let waiting = ticked.filter { !plan.canConvert($0) }.count
        // Scrolls rather than setting the pane's height, so a short window never pushes the
        // page's top out of view.
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Convert to").font(.headline)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(OutputPreset.allCases, id: \.self) { p in
                        ConvertPresetRow(preset: p, chosen: p == plan.preset) { state.convertPlan.preset = p }
                    }
                }
                Divider()
                Label(summary(ticked: ticked.count, total: plan.items.count, waiting: waiting),
                      systemImage: waiting > 0 ? "exclamationmark.triangle" : "arrow.left.arrow.right")
                    .foregroundStyle(waiting > 0 ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if plan.preset.isThirdWave {
                    Text("Send to Pack converts the ticked tables and adds the .wt files to the Pack page, to embed in programs.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) { advanced }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .visibleScrollers()
    }

    private func summary(ticked: Int, total: Int, waiting: Int) -> String {
        var s = "\(ticked) of \(total) table\(total == 1 ? "" : "s") ticked to convert"
        if waiting > 0 { s += "; \(waiting) still need\(waiting == 1 ? "s" : "") a frame size" }
        return s
    }

    @ViewBuilder private var advanced: some View {
        let preset = state.convertPlan.preset
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("When the destination needs a different number of frames")
                Picker("", selection: $state.convertPlan.options.frameCountPolicy) {
                    Text("Pick evenly").tag(FrameCountPolicy.pickEvenly)
                    Text("Interpolate").tag(FrameCountPolicy.interpolate)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Pick evenly keeps the first and last frames and spaces the rest evenly, adding no new waveforms. Interpolate crossfades between neighbouring frames. The report after converting says what was done.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Interpolation to record")
                Picker("", selection: $state.convertPlan.options.interpolation) {
                    Text("As the source says").tag(Optional<Interpolation>.none)
                    Text("None (steps between frames)").tag(Optional<Interpolation>.some(Interpolation.none))
                    Text("Crossfade").tag(Optional<Interpolation>.some(Interpolation.crossfade))
                    Text("Spectral").tag(Optional<Interpolation>.some(Interpolation.spectral))
                }
                .labelsHidden()
                Text("Only for destinations whose files can say: the clm chunk of a WAV, a Tonverk file name.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if preset == .tonverk {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tonverk frame size")
                    Picker("", selection: $state.convertPlan.options.tonverkFrameSize) {
                        Text("The source's, if Tonverk takes it; otherwise 2,048").tag(Optional<Int>.none)
                        ForEach([64, 128, 256, 512, 1024, 2048, 4096], id: \.self) { n in
                            Text(ConvertPlan.formatCount(n)).tag(Optional<Int>.some(n))
                        }
                    }
                    .labelsHidden()
                    Text("Written into the file name (_wt<N>), which is where Tonverk reads it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if preset == .thirdWaveP {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Put the PPG standard waves in frames 60–63", isOn: $state.convertPlan.options.appendPPGStandardWaves)
                        .toggleStyle(.checkbox)
                    Text("Triangle, narrow pulse, square, and sawtooth, as in the 3rd Wave's PPG-derived P tables. The table itself is fitted into frames 0–59 first, by the choice above, so its whole sweep is kept.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 6)
    }
}

/// One destination: its title, whether it has been tested and where, and what it rests on.
struct ConvertPresetRow: View {
    let preset: OutputPreset
    let chosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title).fixedSize(horizontal: false, vertical: true)
                    ConvertEvidenceLabel(preset: preset)
                    Text(preset.basis).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Tested in …", or that the preset has not been tested in its destination yet (its `basis`, shown
/// below it, says what it rests on).
struct ConvertEvidenceLabel: View {
    let preset: OutputPreset
    var body: some View {
        let tested = preset.testedIn
        if tested.isEmpty {
            Label("Not yet tested in its destination", systemImage: "doc.text")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Tested in " + ConvertPlan.listPhrase(tested), systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.green)
        }
    }
}
