import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(PgdataFormats)
import PgdataFormats
#endif

struct UnpackView: View {
    @EnvironmentObject var state: AppState
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button("Add Files…") { state.add(urls: Panels.chooseFiles(message: "Choose .pgdata files to unpack")) }
                Toggle("Skip wavetables identical to the factory table in their slot", isOn: $state.skipFactoryDuplicates)
                    .help("Needs the factory folders set under Synth Slots. Each table can still be ticked individually.")
                Spacer()
                Button("Remove") { state.removeUnpacks(selection); selection = [] }.disabled(selection.isEmpty)
                Button("Unpack Selected…") { state.unpack(Array(selection)) }.disabled(selection.isEmpty)
                Button("Unpack All…") { state.unpack(state.unpacks.map(\.id)) }.disabled(state.unpacks.isEmpty)
            }
            .padding(10)
            Divider()
            if state.unpacks.isEmpty {
                EmptyHint(title: "Drop .pgdata files here",
                          detail: "Each one is split into its program (.pro), the wavetables it carries (.wt) and its multisamples (.bin, named with their S slot the way Groove's own files are).")
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
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 420)
                    .onChange(of: selection) { s in state.selectedUnpack = s.first }
                    .onAppear { if let s = state.selectedUnpack { selection = [s] } }

                    if let id = state.selectedUnpack, let u = state.unpacks.first(where: { $0.id == id }) {
                        UnpackDetail(item: u)
                    } else {
                        Text("Select a file").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
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
                Button("Show File") { Panels.reveal(item.url) }.buttonStyle(.link)
            }
            Text("Files to write").font(.headline)
            Table(item.plan.items) {
                TableColumn("Write") { (f: UnpackPlan.Item) in WriteToggleCell(state: st, unpackID: item.id, file: f) }
                    .width(44)
                TableColumn("File name") { (f: UnpackPlan.Item) in FileNameCell(state: st, unpackID: item.id, file: f) }
                    .width(min: 180, ideal: 260)
                TableColumn("Contents") { (f: UnpackPlan.Item) in Text(f.description).foregroundStyle(.secondary).lineLimit(2) }
            }
            .frame(minHeight: 140)
            if !item.plan.referenced.isEmpty {
                Text("Listed but not carried (the synth is expected to have these already): "
                     + item.plan.referenced.map(\.description).joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(item.plan.notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
            }
            Text("Multisamples are named with the S slot they came from. Load them into those slots (Global → Import Multisample) before importing the .pro, or the program will point at whatever is in that slot.")
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
            .textFieldStyle(.plain)
    }
}
