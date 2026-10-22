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
                    .help("Leave out wavetables that are identical to the factory table in their slot. The synth's own exports embed factory tables too; a repack lists the factory slot instead. Any table can still be ticked.")
                if let p = state.reading {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 120)
                    Text("Reading \(p.done) of \(p.total)…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove") { state.removeUnpacks(selection); selection = [] }.disabled(selection.isEmpty)
                    .help("Remove the selected files from this list (the files are not touched)")
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
            if !item.plan.referenced.isEmpty {
                Text("Not embedded (the synth plays what it has in these slots): "
                     + item.plan.referenced.map(\.description).joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(item.plan.notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
            }
            Text("Multisamples are named with their S slot. Import them into those slots before importing the .pro, or the program will play whatever is there.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
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
