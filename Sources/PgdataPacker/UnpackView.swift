import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(PgdataFormats)
import PgdataFormats
#endif
#if canImport(PgdataPackerCore)
import PgdataPackerCore
#endif

struct UnpackView: View {
    @EnvironmentObject var state: AppState
    @State private var selection = Set<UUID>()
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button("Add Files or Folders…") { state.add(urls: Panels.chooseFiles(message: "Choose .pgdata files to unpack")) }
                    .keyboardShortcut("o")
                Toggle("Skip factory wavetables", isOn: $state.skipFactoryDuplicates)
                    .help("Leave out wavetables that are identical to the factory table in their slot. The 3rd Wave's own exports embed factory tables too; a repack lists the factory slot instead. Any table can still be ticked.")
                Spacer()
                Button("Remove Selected") { state.removeUnpacks(selection); selection = [] }.disabled(selection.isEmpty)
                    .help("Remove the selected files from this list (the files are not touched)")
                Button("Remove All…") { state.removeAllUnpacks(); if state.unpacks.isEmpty { selection = [] } }
                    .disabled(state.unpacks.isEmpty)
                    .help("Remove every file from this list (the files are not touched)")
                Button("Unpack Selected…") { state.unpack(Array(selection)) }.disabled(selection.isEmpty)
                Button("Unpack All…") { state.unpack(state.unpacks.map(\.id)) }.disabled(state.unpacks.isEmpty)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .buttonStyle(.borderedProminent)
            }
            .padding(10)
            Divider()
            if state.unpacks.isEmpty {
                EmptyHint(title: "Drop .pgdata files here",
                          detail: "Each is split into its program (.pro), its embedded wavetables (.wt) and its multisamples (.bin, named with their S slot).")
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(state.unpacks) { u in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(u.plan.programName).lineLimit(1)
                                Text(u.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .tag(u.id)
                        }
                    }
                    .visibleScrollers()
                    .onDeleteCommand { state.removeUnpacks(selection); selection = [] }
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 420)
                    .onChange(of: selection) { s in
                        if let cur = state.selectedUnpack, s.contains(cur) { return }
                        state.selectedUnpack = state.unpacks.first { s.contains($0.id) }?.id
                    }
                    .onChange(of: state.selectedUnpack) { s in if let s, !selection.contains(s) { selection = [s] } }
                    .onAppear { if let s = state.selectedUnpack { selection = [s] } }

                    // Every selected file, in list order; with several, the detail covers them all.
                    let chosen = state.unpacks.filter { selection.contains($0.id) }
                    Group {
                        if chosen.isEmpty {
                            Text("Select a file").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            UnpackDetail(items: chosen)
                        }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .dropHighlight(dropTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            DropSupport.load(providers) { state.add(urls: $0) }
            return true
        }
    }
}

/// The files one or more .pgdata will produce. With several selected, the table lists every file
/// with the program it comes from, and the box above covers them all.
struct UnpackDetail: View {
    @EnvironmentObject var state: AppState
    let items: [AppState.UnpackItem]

    /// One table row: a file and the .pgdata it comes from.
    struct Row: Identifiable {
        let unpackID: UUID
        let programName: String
        let file: UnpackPlan.Item
        var id: UUID { file.id }
    }

    var body: some View {
        let st = state
        let several = items.count > 1
        let rows = items.flatMap { u in u.plan.items.map { Row(unpackID: u.id, programName: u.plan.programName, file: $0) } }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(several ? "\(items.count) files selected" : items[0].plan.programName).font(.title2)
                Spacer()
                if !several {
                    Button("Show in Finder") { Panels.reveal(items[0].url) }.buttonStyle(.link)
                }
            }
            BeforeImportBox(items: items)
            Text(several ? "Files these will produce" : "Files this will produce").font(.headline)
            // Write first (ticks in one line at the left), Contents last (the widest column). The
            // Program column only with several files; macOS 13 has no conditional table columns,
            // so there are two tables.
            Group {
                if several {
                    Table(rows) {
                        TableColumn("Write") { (r: Row) in WriteToggleCell(state: st, unpackID: r.unpackID, file: r.file) }
                            .width(44)
                        TableColumn("Program") { (r: Row) in Text(r.programName).lineLimit(1) }
                            .width(min: 80, ideal: 150)
                        TableColumn("File name") { (r: Row) in FileNameCell(state: st, unpackID: r.unpackID, file: r.file) }
                            .width(min: 180, ideal: 260)
                        TableColumn("Contents") { (r: Row) in Text(r.file.description).foregroundStyle(.secondary).lineLimit(2) }
                    }
                } else {
                    Table(rows) {
                        TableColumn("Write") { (r: Row) in WriteToggleCell(state: st, unpackID: r.unpackID, file: r.file) }
                            .width(44)
                        TableColumn("File name") { (r: Row) in FileNameCell(state: st, unpackID: r.unpackID, file: r.file) }
                            .width(min: 180, ideal: 260)
                        TableColumn("Contents") { (r: Row) in Text(r.file.description).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
            .visibleScrollers()
            .frame(minHeight: 140, maxHeight: .infinity)
            if several {
                Text("A file that several programs share, with the same name and contents, is written once.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// What the programs need on the 3rd Wave (multisamples to load first, slots they play from),
/// above the file table so it is seen first. Each line appears only when it applies; with nothing to say, the box is left
/// out. Its text wraps but never sets the pane's height: a fixed-height Text here once made the
/// page taller than the window and pushed its top out of view.
struct BeforeImportBox: View {
    @EnvironmentObject var state: AppState
    let items: [AppState.UnpackItem]

    var body: some View {
        let lines = messages
        if !lines.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(items.count > 1 ? "What these programs need on your 3rd Wave" : "What this program needs on your 3rd Wave")
                        .font(.headline)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, m in
                        line(m.text, warning: m.warning)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    /// Multisamples to import first, factory slots the programs play from, other slots listed
    /// without data, then the unpacker's notes (named by program when several are selected).
    private var messages: [(text: String, warning: Bool)] {
        var out: [(text: String, warning: Bool)] = []
        let samples = multisamples
        if samples.count == 1 {
            let s = samples[0]
            out.append(("Import multisample \(quoted(s.name)) into slot \(s.slot) before importing the .pro, "
                        + "or the program will play whatever is in \(s.slot).", false))
        } else if samples.count > 1 {
            let list = samples.map { "\($0.slot) \(quoted($0.name))" }.joined(separator: ", ")
            out.append(("Import these multisamples into their slots before importing the .pro files, "
                        + "or the programs will play whatever is there: \(list).", false))
        }
        // Different multisamples labelled with the same slot cannot all go in it.
        var bySlot: [String: [String]] = [:]
        for s in samples { bySlot[s.slot, default: []].append(s.name) }
        for slot in bySlot.keys.sorted() {
            guard let names = bySlot[slot], names.count > 1 else { continue }
            let list = names.map { quoted($0) }.joined(separator: " and ")
            let all = names.count == 2 ? "both" : "all"
            out.append(("\(list) are \(all) labelled \(slot), but only one can be in that slot. "
                        + "Whichever is there is what every program using \(slot) plays.", true))
        }
        var refs: [SourceRef] = []
        for u in items { for r in u.plan.referenced where !refs.contains(r) { refs.append(r) } }
        refs.sort()
        let factory = refs.filter { $0.isFactorySlot }
        let other = refs.filter { !$0.isFactorySlot }
        let several = items.count > 1
        let file = several ? "these files" : "this file"
        let plays = several ? "The programs play" : "The program plays"
        if !factory.isEmpty {
            let list = factory.map { slotText($0) }.joined(separator: ", ")
            out.append(("Plays from your 3rd Wave (not in \(file)): \(list).", false))
        }
        if !other.isEmpty {
            let list = other.map { $0.description }.joined(separator: ", ")
            out.append(("Not in \(file), and not factory slots: \(list). \(plays) whatever your 3rd Wave has there.", true))
        }
        for u in items {
            for n in u.plan.notes { out.append((several ? "\(u.plan.programName): \(n)" : n, true)) }
        }
        return out
    }

    /// The multisamples the files carry (slot label and name), each distinct one once, in order.
    private var multisamples: [(slot: String, name: String)] {
        var out: [(slot: String, name: String)] = []
        for u in items {
            for src in u.unified.sources {
                guard case let .multisample(m) = src.payload else { continue }
                let s = (slot: src.ref.label, name: m.name)
                if !out.contains(where: { $0.slot == s.slot && $0.name == s.name }) { out.append(s) }
            }
        }
        return out
    }

    private func quoted(_ s: String) -> String { "\u{201C}\(s)\u{201D}" }

    /// A factory slot with its table name (e.g., "U07 Knob Grotto 6"; "P02" alone, not
    /// "P02 Wavetable P02").
    private func slotText(_ ref: SourceRef) -> String { state.labelledSlot(ref, separator: " ") }

    private func line(_ text: String, warning: Bool) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: warning ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(warning ? Color.orange : Color.secondary)
        }
        .foregroundStyle(warning ? Color.orange : Color.primary)
    }
}

struct WriteToggleCell: View {
    @ObservedObject var state: AppState
    let unpackID: UUID
    let file: UnpackPlan.Item
    var body: some View {
        Toggle("", isOn: Binding(get: { file.write }, set: { state.setUnpackItem(unpackID, file.id, write: $0) }))
            .labelsHidden()
            .help(file.isFactoryDuplicate ? "Identical to the factory table in this slot" : "")
    }
}

/// The file name, edited freely and cleaned when editing ends (Return or leaving the field), so
/// typing a space does not have it trimmed away under the cursor.
struct FileNameCell: View {
    @ObservedObject var state: AppState
    let unpackID: UUID
    let file: UnpackPlan.Item
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { text = file.fileName }
            .onChange(of: file.fileName) { text = $0 }
            .onSubmit { commit() }
            .onChange(of: focused) { if !$0 { commit() } }
    }

    private func commit() { text = state.commitUnpackFileName(unpackID, file.id, text) }
}
