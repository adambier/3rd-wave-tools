import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(PgdataFormats)
import PgdataFormats
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

                    if let id = state.selectedUnpack, let u = state.unpacks.first(where: { $0.id == id }) {
                        UnpackDetail(item: u)
                    } else {
                        Text("Select a file").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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

struct UnpackDetail: View {
    @EnvironmentObject var state: AppState
    let item: AppState.UnpackItem

    var body: some View {
        let st = state
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.plan.programName).font(.title2)
                Spacer()
                Button("Show in Finder") { Panels.reveal(item.url) }.buttonStyle(.link)
            }
            BeforeImportBox(item: item)
            Text("Files this will produce").font(.headline)
            Table(item.plan.items) {
                TableColumn("Write") { (f: UnpackPlan.Item) in WriteToggleCell(state: st, unpackID: item.id, file: f) }
                    .width(44)
                TableColumn("File name") { (f: UnpackPlan.Item) in FileNameCell(state: st, unpackID: item.id, file: f) }
                    .width(min: 180, ideal: 260)
                TableColumn("Contents") { (f: UnpackPlan.Item) in Text(f.description).foregroundStyle(.secondary).lineLimit(2) }
            }
            .visibleScrollers()
            .frame(minHeight: 140)
        }
        .padding(12)
    }
}

/// What to do on the 3rd Wave before importing the unpacked .pro, above the file table so it is
/// seen first. Each line appears only when it applies; with nothing to say, the box is left out.
struct BeforeImportBox: View {
    @EnvironmentObject var state: AppState
    let item: AppState.UnpackItem

    var body: some View {
        let lines = messages
        if !lines.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Before importing on your 3rd Wave").font(.headline)
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

    /// Multisamples to import first, factory slots the program plays from, other slots it lists
    /// without data, then the unpacker's notes.
    private var messages: [(text: String, warning: Bool)] {
        var out: [(text: String, warning: Bool)] = []
        let samples = multisamples
        if samples.count == 1 {
            let s = samples[0]
            out.append(("Import multisample \(quoted(s.name)) into slot \(s.slot) before importing the .pro, "
                        + "or the program will play whatever is in \(s.slot).", false))
        } else if samples.count > 1 {
            let list = samples.map { "\($0.slot) \(quoted($0.name))" }.joined(separator: ", ")
            out.append(("Import these multisamples into their slots before importing the .pro, "
                        + "or the program will play whatever is there: \(list).", false))
        }
        let refs = item.plan.referenced
        let factory = refs.filter { $0.isFactorySlot }
        let other = refs.filter { !$0.isFactorySlot }
        if !factory.isEmpty {
            let list = factory.map { slotText($0) }.joined(separator: ", ")
            out.append(("Plays from your 3rd Wave (not in this file): \(list).", false))
        }
        if !other.isEmpty {
            let list = other.map { $0.description }.joined(separator: ", ")
            out.append(("Not in this file, and not factory slots: \(list). "
                        + "The program plays whatever your 3rd Wave has there.", true))
        }
        for n in item.plan.notes { out.append((n, true)) }
        return out
    }

    /// The multisamples the file carries (slot label and name), in the order they are listed.
    private var multisamples: [(slot: String, name: String)] {
        var out: [(slot: String, name: String)] = []
        for src in item.unified.sources {
            if case let .multisample(m) = src.payload { out.append((src.ref.label, m.name)) }
        }
        return out
    }

    private func quoted(_ s: String) -> String { "\u{201C}\(s)\u{201D}" }

    /// A factory slot with its table name (e.g., "U07 Knob Grotto 6").
    private func slotText(_ ref: SourceRef) -> String {
        if let name = state.factory.name(ref) { return "\(ref.label) \(name)" }
        return ref.label
    }

    private func line(_ text: String, warning: Bool) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
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

struct FileNameCell: View {
    @ObservedObject var state: AppState
    let unpackID: UUID
    let file: UnpackPlan.Item
    var body: some View {
        TextField("", text: Binding(get: { file.fileName }, set: { state.setUnpackItem(unpackID, file.id, fileName: $0) }))
            .textFieldStyle(.roundedBorder)
    }
}
