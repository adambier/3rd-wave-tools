import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(PgdataFormats)
import PgdataFormats
#endif

struct PackView: View {
    @EnvironmentObject var state: AppState
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if state.programs.isEmpty && state.contentFiles.isEmpty {
                EmptyHint(title: "Drop programs and their wavetables or samples here",
                          detail: "Add .pro files, plus any .wt and .bin files they use. For each program the app works out which wavetables and samples it needs, and whether a .pgdata is needed at all.")
            } else {
                HSplitView {
                    programList.frame(minWidth: 200, idealWidth: 240, maxWidth: 420)
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
        .sheet(item: $state.repointRequest) { req in RepointSheet(state: state, request: req) }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button("Add Files…") { state.add(urls: Panels.chooseFiles(message: "Choose .pro programs and the .wt / .bin files they use")) }
            Button("Clean Up Names…") { state.showNameCleanup = true }
                .disabled(state.programs.isEmpty && state.contentFiles.isEmpty)
                .help("Propose tidier names (slot numbers removed, title case) for the programs and the wavetables and samples you added. Factory wavetables are not renamed.")
                .sheet(isPresented: $state.showNameCleanup) { NameCleanupSheet(state: state) }
            Spacer()
            Button("Remove") { state.removePrograms(selection); selection = [] }.disabled(selection.isEmpty)
            Button("Write Selected…") { state.writeUnified(Array(selection)) }.disabled(selection.isEmpty)
            Button("Write All…") { state.writeUnified(state.programs.map(\.id)) }.disabled(state.programs.isEmpty)
        }
        .padding(10)
    }

    private var programList: some View {
        let st = state
        return List(selection: $selection) {
            ForEach(st.programs) { item in
                ProgramRow(state: st, item: item).tag(item.id)
            }
        }
        .visibleScrollers()
        .onChange(of: selection) { s in state.selectedProgram = s.first }
        .onChange(of: state.selectedProgram) { s in if let s, !selection.contains(s) { selection = [s] } }
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

struct SizeLine: View {
    let plan: PackPlan
    var body: some View {
        HStack(spacing: 8) {
            Text("Estimated .pgdata size: \(PackPlan.formatBytes(plan.estimatedBytes))").foregroundStyle(.secondary)
        }
        .font(.callout)
        let need = plan.slotsNeeded
        if need.u + need.p > 0 {
            let parts = [need.u > 0 ? "\(need.u) U" : nil, need.p > 0 ? "\(need.p) P" : nil].compactMap { $0 }
            Label("New wavetables: importing needs \(parts.joined(separator: " and ")) free slot\(need.u + need.p == 1 ? "" : "s") on the synth. If it has none, it offers to overwrite its last ones (blank placeholder tables count as used).",
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
                .help("The synth reuses any table whose content it already has, in any slot and whatever its name, and stores new ones in free slots. The slot numbers in the file are only labels.")
        }
    }
}

struct ProgramRow: View {
    @ObservedObject var state: AppState
    let item: AppState.PackItem

    var body: some View {
        let verdict = state.plan(for: item).verdict
        HStack {
            Image(systemName: verdict.symbol).foregroundStyle(verdict.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(item.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct ProgramDetail: View {
    @EnvironmentObject var state: AppState
    let item: AppState.PackItem

    var body: some View {
        let st = state
        let plan = st.plan(for: item)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Program name", text: Binding(
                    get: { item.newName ?? item.program.name },
                    set: { st.setProgramName(item.id, $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.title2)
                .frame(maxWidth: 380)
                .help("The name written into the .pgdata. The .pro file is not changed.")
                if item.name != item.program.name {
                    Text("was \(item.program.name)").font(.caption).foregroundStyle(.secondary)
                    Button { st.setProgramName(item.id, nil) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless).help("Restore the name from the .pro file")
                }
                NameLengthNote(name: item.name)
                Text(item.program.version).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show File") { Panels.reveal(item.url) }.buttonStyle(.link)
            }
            VerdictBadge(verdict: plan.verdict)
            if let note = plan.userSlotNote { UserSlotNoteBox(note: note) }
            ForEach(plan.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            SizeLine(plan: plan)
            Table(plan.rows) {
                TableColumn("Source") { (row: PackPlan.Row) in SourceCell(state: st, itemID: item.id, row: row) }
                    .width(min: 70, ideal: 110, max: 180)
                TableColumn("Used by") { (row: PackPlan.Row) in UsedByCell(usedBy: row.usedBy) }
                    .width(min: 90, ideal: 110, max: 220)
                TableColumn("Content") { (row: PackPlan.Row) in ChoiceCell(state: st, itemID: item.id, row: row) }
                    .width(min: 200, ideal: 240)
                TableColumn("Status") { (row: PackPlan.Row) in StatusText(status: row.status).lineLimit(2) }
                    .width(min: 240, ideal: 320)
            }
            .visibleScrollers()
            // Keeps several rows visible however long the note above is.
            .frame(minHeight: 150)
        }
        .padding(12)
    }
}

/// Why U48–U55 are missing in a program made before they were factory slots, and the choices.
/// Paragraphs are separated by blank lines in the note; lines starting with "• " are bullets, set
/// with a hanging indent and half a line of space above and below each.
struct UserSlotNoteBox: View {
    let note: PackPlan.Note
    /// Half the height of a line of body text.
    private let halfLine: CGFloat = 8

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(note.title, systemImage: "questionmark.circle")
                    .font(.headline).foregroundStyle(.red)
                ForEach(Array(note.body.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, para in
                    paragraph(para)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 820, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder private func paragraph(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        let lead = lines.filter { !$0.hasPrefix("• ") }.joined(separator: "\n")
        let bullets = lines.filter { $0.hasPrefix("• ") }.map { String($0.dropFirst(2)) }
        VStack(alignment: .leading, spacing: 0) {
            if !lead.isEmpty { Text(lead).fixedSize(horizontal: false, vertical: true) }
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: halfLine) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, b in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text(b).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, halfLine)
                .padding(.leading, 4)
            }
        }
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

struct SourceCell: View {
    @ObservedObject var state: AppState
    let itemID: UUID
    let row: PackPlan.Row

    var body: some View {
        if row.repointedFrom.isEmpty {
            Text(row.ref.description).monospacedDigit()
        } else {
            let from = row.repointedFrom.map(\.label).joined(separator: ", ")
            HStack(spacing: 4) {
                Text("\(from) → \(row.ref.label)").monospacedDigit().foregroundStyle(.blue)
                Button { state.undoRepoints(itemID, to: row.ref) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Point \(row.usedBy.joined(separator: ", ")) back to \(from), as in the .pro file")
            }
        }
    }
}

/// The Content menu: the choices for this source, plus "Point to another slot…" for wavetables
/// and analog shapes.
struct ChoiceCell: View {
    @ObservedObject var state: AppState
    let itemID: UUID
    let row: PackPlan.Row

    private func repoint() { state.repointRequest = .init(itemID: itemID, from: row.ref) }

    @ViewBuilder private var optionItems: some View {
        ForEach(row.options, id: \.self) { c in
            Button { state.setOverride(itemID, row.ref, c) } label: {
                if c == row.choice { Label(state.describe(c, for: row.ref), systemImage: "checkmark") }
                else { Text(state.describe(c, for: row.ref)) }
            }
        }
    }

    var body: some View {
        let canRepoint = !row.ref.isSample
        if !canRepoint && row.options.count <= 1 {
            if let c = row.choice { Text(state.describe(c, for: row.ref)).lineLimit(1) }
            else { Text("—").foregroundStyle(.secondary) }
        } else if row.choice == nil && canRepoint {
            // Nothing for this slot yet: pointing the oscillators elsewhere is the usual fix, so it
            // comes first and is what a click on the button does; the chevron shows the rest.
            Menu {
                Button("Point to another slot…", action: repoint)
                if !row.options.isEmpty { Divider() }
                optionItems
            } label: {
                Text("Point to another slot…").lineLimit(1)
            } primaryAction: {
                repoint()
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.visible)
        } else {
            Menu {
                optionItems
                if canRepoint {
                    if !row.options.isEmpty { Divider() }
                    Button("Point to another slot…", action: repoint)
                }
            } label: {
                Text(row.choice.map { state.describe($0, for: row.ref) } ?? "Choose…").lineLimit(1)
            }
            // A bordered pop-up with its chevron, so it reads as a menu rather than as text.
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.visible)
        }
    }
}

// MARK: - Wavetable and sample files added for packing

struct ContentFilesTable: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let st = state
        let unused = st.unusedContent
        VStack(alignment: .leading, spacing: 4) {
            Text("Wavetables and samples for packing").font(.headline).padding(.horizontal, 12).padding(.top, 8)
            Text("Assign each file to the slot the programs refer to. A file assigned to a slot is used for every program here that uses that slot.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            Table(st.contentFiles) {
                // Most important first: what the file is, its slot, and whether anything uses it.
                TableColumn("File") { (f: ContentFile) in Text(f.url.lastPathComponent).lineLimit(1).help(f.url.path) }
                    .width(min: 120, ideal: 170)
                TableColumn("Name") { (f: ContentFile) in
                    Text(st.displayName(f)).lineLimit(1).help(st.contentNames[f.id] != nil ? "Was \(f.name)" : f.name)
                }
                    .width(min: 90, ideal: 130)
                TableColumn("Slot") { (f: ContentFile) in SlotPickerCell(state: st, file: f) }
                    .width(min: 110, ideal: 120)
                TableColumn("Used") { (f: ContentFile) in UsageCell(state: st, file: f, note: unused[f.id]) }
                    .width(min: 180, ideal: 300)
                TableColumn("Kind") { (f: ContentFile) in Text(f.kindLabel).foregroundStyle(.secondary).lineLimit(1).help(f.kindLabel) }
                    .width(min: 160, ideal: 180)
                TableColumn("") { (f: ContentFile) in
                    Button { st.removeContent(f.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove")
                }
                .width(28)
            }
            .visibleScrollers()
        }
    }
}

struct SlotPickerCell: View {
    @ObservedObject var state: AppState
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

struct UsageCell: View {
    @ObservedObject var state: AppState
    let file: ContentFile
    let note: String?

    var body: some View {
        if let note {
            HStack(spacing: 6) {
                Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1).help(note)
                if !file.isSample, !state.programs.isEmpty {
                    Button("Use in a program…") { state.repointRequest = .init(fileID: file.id) }
                        .buttonStyle(.link)
                }
            }
        } else {
            Text("Yes").foregroundStyle(.secondary)
        }
    }
}
