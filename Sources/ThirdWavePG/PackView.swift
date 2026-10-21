import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(ThirdWaveFormats)
import ThirdWaveFormats
#endif

struct PackView: View {
    @EnvironmentObject var state: AppState
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if state.programs.isEmpty && state.contentFiles.isEmpty {
                EmptyHint(title: "Drop programs and their wavetables or samples here",
                          detail: "Add .pro files, plus any .wt and .bin files they use. For each program the app works out which wavetables and samples it needs, and whether a .pgdata is needed at all.")
            } else {
                HSplitView {
                    programList.frame(minWidth: 230, idealWidth: 270, maxWidth: 420)
                    VSplitView {
                        detail.frame(minHeight: 220)
                        ContentFilesTable().frame(minHeight: 120, idealHeight: 190)
                    }
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            DropSupport.load(providers) { state.add(urls: $0) }
            return true
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button("Add Files…") { state.add(urls: Panels.chooseFiles(message: "Choose .pro programs and the .wt / .bin files they use")) }
            Toggle("Embed factory wavetables", isOn: $state.embedFactory)
                .help("Off: factory tables are listed but not carried (Groove's own sample library does this). On: they are embedded, for sharing with synths whose factory slots may differ. Needs the factory folders set under Synth Slots.")
            Toggle("Write a .pgdata even when the .pro is enough", isOn: $state.writeWhenNotNeeded)
            Spacer()
            Button("Remove") { state.removePrograms(selection); selection = [] }.disabled(selection.isEmpty)
            Button("Write Selected…") { state.writeUnified(Array(selection)) }.disabled(selection.isEmpty)
            Button("Write All…") { state.writeUnified(state.programs.map(\.id)) }.disabled(state.programs.isEmpty)
        }
        .padding(10)
    }

    private var programList: some View {
        List(selection: $selection) {
            ForEach(state.programs) { item in
                ProgramRow(item: item).tag(item.id)
            }
        }
        .onChange(of: selection) { s in state.selectedProgram = s.first }
        .onAppear { if let s = state.selectedProgram { selection = [s] } }
    }

    @ViewBuilder private var detail: some View {
        if let id = state.selectedProgram, let item = state.programs.first(where: { $0.id == id }) {
            ProgramDetail(item: item)
        } else {
            Text("Select a program").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProgramRow: View {
    @EnvironmentObject var state: AppState
    let item: AppState.PackItem

    var body: some View {
        let verdict = state.plan(for: item).verdict
        HStack {
            Image(systemName: verdict.symbol).foregroundStyle(verdict.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.program.name).lineLimit(1)
                Text(item.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct ProgramDetail: View {
    @EnvironmentObject var state: AppState
    let item: AppState.PackItem

    var body: some View {
        let plan = state.plan(for: item)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.program.name).font(.title2)
                Text(item.program.version).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show File") { Panels.reveal(item.url) }.buttonStyle(.link)
            }
            VerdictBadge(verdict: plan.verdict)
            Table(plan.rows) {
                TableColumn("Source") { row in Text(row.ref.description).monospacedDigit() }
                    .width(min: 70, ideal: 90, max: 130)
                TableColumn("Used by") { row in UsedByCell(usedBy: row.usedBy) }
                    .width(min: 90, ideal: 130, max: 220)
                TableColumn("Content") { row in ChoiceCell(itemID: item.id, row: row) }
                    .width(min: 200, ideal: 300)
                TableColumn("Status") { row in StatusText(status: row.status).lineLimit(2) }
            }
        }
        .padding(12)
    }
}

struct UsedByCell: View {
    let usedBy: [String]
    var body: some View {
        Text(usedBy.count <= 2 ? usedBy.joined(separator: ", ") : "\(usedBy[0]) +\(usedBy.count - 1)")
            .help(usedBy.joined(separator: "\n"))
            .foregroundStyle(.secondary)
    }
}

struct ChoiceCell: View {
    @EnvironmentObject var state: AppState
    let itemID: UUID
    let row: PackPlan.Row

    var body: some View {
        if row.options.count <= 1, let c = row.choice {
            Text(state.describe(c, for: row.ref)).lineLimit(1)
        } else if row.options.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            Picker("", selection: Binding<PackPlan.Choice?>(
                get: { row.choice },
                set: { state.setOverride(itemID, row.ref, $0) }
            )) {
                if row.choice == nil { Text("Choose…").tag(PackPlan.Choice?.none) }
                ForEach(row.options, id: \.self) { c in
                    Text(state.describe(c, for: row.ref)).tag(PackPlan.Choice?.some(c))
                }
            }
            .labelsHidden()
        }
    }
}

// MARK: - Wavetable and sample files added for packing

struct ContentFilesTable: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wavetables and samples for packing").font(.headline).padding(.horizontal, 12).padding(.top, 8)
            Text("Assign each file to the slot the programs refer to. A file assigned to a slot is used for every program here that uses that slot.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            Table(state.contentFiles) {
                TableColumn("File") { f in Text(f.url.lastPathComponent).lineLimit(1).help(f.url.path) }
                    .width(min: 140, ideal: 220)
                TableColumn("Name") { f in Text(f.name).lineLimit(1) }
                    .width(min: 100, ideal: 160)
                TableColumn("Kind") { f in Text(f.kindLabel).foregroundStyle(.secondary) }
                    .width(min: 110, ideal: 150)
                TableColumn("Slot") { f in SlotPickerCell(file: f) }
                    .width(min: 120, ideal: 140)
                TableColumn("") { f in
                    Button { state.removeContent(f.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove")
                }
                .width(28)
            }
        }
    }
}

struct SlotPickerCell: View {
    @EnvironmentObject var state: AppState
    let file: ContentFile

    private var slots: [SourceRef] {
        if file.isSample { return (0...SourceRef.sMax).map { SourceRef.s($0) } }
        if file.isPTable { return (0..<SourceRef.pCount).map { SourceRef.p($0) } }
        return (0..<SourceRef.uCount).map { SourceRef.u($0) }
    }

    var body: some View {
        Picker("", selection: Binding<SourceRef?>(
            get: { file.slot },
            set: { state.setSlot(file.id, $0) }
        )) {
            Text("Not assigned").tag(SourceRef?.none)
            ForEach(slots, id: \.self) { s in
                Text(s.label + (s.isFactorySlot ? "  (factory slot)" : "")).tag(SourceRef?.some(s))
            }
        }
        .labelsHidden()
    }
}
