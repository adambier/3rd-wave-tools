import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(PgdataFormats)
import PgdataFormats
#endif

struct PackView: View {
    @EnvironmentObject var state: AppState
    @State private var selection = Set<UUID>()
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if state.programs.isEmpty && state.contentFiles.isEmpty {
                EmptyHint(title: "Drop programs and their wavetables or samples here",
                          detail: "Add .pro files and the .wt and .bin files they use (folders work too). Each program then shows what its oscillators play and which files will be embedded.")
            } else {
                HSplitView {
                    programList.frame(minWidth: 220, idealWidth: 260, maxWidth: 440)
                    VSplitView {
                        detail.frame(minHeight: 220)
                        ContentFilesTable().frame(minHeight: 120, idealHeight: 190)
                    }
                }
            }
        }
        .dropHighlight(dropTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            DropSupport.load(providers) { state.add(urls: $0) }
            return true
        }
        .sheet(item: $state.repointRequest) { req in RepointSheet(state: state, request: req) }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button("Add Files or Folders…") { state.add(urls: Panels.chooseFiles(message: "Choose .pro programs and the .wt and .bin files they use")) }
                .keyboardShortcut("o")
            Button("Clean Up Names…") { state.showNameCleanup = true }
                .disabled(state.programs.isEmpty && state.contentFiles.isEmpty)
                .help("Propose tidier names for the programs and the files you added (e.g., slot numbers removed, title case). Factory wavetables keep their names.")
                .sheet(isPresented: $state.showNameCleanup) { NameCleanupSheet(state: state) }
            if let p = state.loading {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .frame(width: 120)
                Text("Reading \(p.done) of \(p.total)…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove") { state.removePrograms(selection); selection = [] }.disabled(selection.isEmpty)
                .help("Remove the selected programs from this list (the files are not touched)")
            Button("Pack Selected…") { state.writeUnified(Array(selection)) }.disabled(selection.isEmpty)
            Button("Pack All…") { state.writeUnified(state.programs.map(\.id)) }.disabled(state.programs.isEmpty)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
    }

    /// Programs matching the filter field and, when asked, only those needing attention.
    private var shownPrograms: [AppState.PackItem] {
        let q = state.programFilter.trimmingCharacters(in: .whitespaces)
        return state.programs.filter { item in
            if state.onlyAttention {
                let plan = state.plan(for: item)
                let blocked: Bool = { if case .blocked = plan.verdict { return true }; return false }()
                let warned = !plan.warnings.isEmpty || plan.rows.contains { if case .warning = $0.status { return true }; return false }
                if !blocked && !warned { return false }
            }
            guard !q.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(q)
                || item.url.lastPathComponent.localizedCaseInsensitiveContains(q)
                || (item.locationLabel?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var programList: some View {
        let st = state
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name or location", text: $state.programFilter)
                    .textFieldStyle(.plain)
                if !state.programFilter.isEmpty {
                    Button { state.programFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Toggle("Only programs needing attention", isOn: $state.onlyAttention)
                .toggleStyle(.checkbox).font(.caption)
                .padding(.horizontal, 10).padding(.bottom, 4)
                .help("Programs that can't be packed yet, or that carry a warning")
            Divider()
            List(selection: $selection) {
                ForEach(shownPrograms) { item in
                    ProgramRow(state: st, item: item).tag(item.id)
                }
            }
            .visibleScrollers()
            .onDeleteCommand { state.removePrograms(selection); selection = [] }
            if shownPrograms.count != state.programs.count {
                Text("\(shownPrograms.count) of \(state.programs.count) programs").font(.caption).foregroundStyle(.secondary).padding(4)
            }
        }
        .onChange(of: selection) { s in
            if let cur = state.selectedProgram, s.contains(cur) { return }
            state.selectedProgram = st.programs.first { s.contains($0.id) }?.id
        }
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

struct ProgramRow: View {
    @ObservedObject var state: AppState
    let item: AppState.PackItem

    var body: some View {
        let verdict = state.plan(for: item).verdict
        HStack {
            Image(systemName: verdict.symbol).foregroundStyle(verdict.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text((item.locationLabel.map { $0 + "  ·  " } ?? "") + item.url.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                .help("The name written into the .pgdata; the .pro file is not changed. Format \(item.program.version), \(item.program.valuesPerPart) values per part.")
                if item.name != item.program.name {
                    Text("was \(item.program.name)").font(.caption).foregroundStyle(.secondary)
                    Button { st.setProgramName(item.id, nil) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless).help("Restore the name from the .pro file")
                }
                NameLengthNote(name: item.name)
                if let loc = item.locationLabel { Text(loc).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                Spacer()
                Button("Show in Finder") { Panels.reveal(item.url) }.buttonStyle(.link)
            }
            PlanSummary(plan: plan)
            if let note = plan.userSlotNote { UserSlotNoteBox(note: note) }
            ForEach(plan.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Table(plan.rows) {
                TableColumn("Source") { (row: PackPlan.Row) in SourceCell(state: st, itemID: item.id, row: row) }
                    .width(min: 70, ideal: 110, max: 180)
                TableColumn("Oscillators") { (row: PackPlan.Row) in UsedByCell(usedBy: row.usedBy) }
                    .width(min: 100, ideal: 150, max: 260)
                TableColumn("Plays") { (row: PackPlan.Row) in ChoiceCell(state: st, itemID: item.id, row: row) }
                    .width(min: 200, ideal: 260)
                TableColumn("Result") { (row: PackPlan.Row) in StatusText(brief: row.brief, status: row.status) }
                    .width(min: 220, ideal: 300)
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

    @State private var expanded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(note.title, systemImage: "questionmark.circle").font(.headline)
                    Spacer()
                    Button(expanded ? "Hide" : "Why, and what to do") { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
                        .buttonStyle(.link).font(.callout)
                }
                if expanded {
                    ForEach(Array(note.body.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, para in
                        paragraph(para)
                    }
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
        Text(usedBy.count <= 2 ? usedBy.joined(separator: ", ") : "\(usedBy[0]) and \(usedBy.count - 1) more")
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

/// The Plays menu: the choices for this source, plus a way to point the oscillators at something
/// else (wavetables and analog waves only).
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
                Button("Choose what to play…", action: repoint)
                if !row.options.isEmpty { Divider() }
                optionItems
            } label: {
                Text("Choose what to play…").lineLimit(1)
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
                    Button("Play something else…", action: repoint)
                }
            } label: {
                Text(row.choice.map { state.describe($0, for: row.ref) } ?? "Choose what to play…").lineLimit(1)
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
            Text("Added wavetables and samples").font(.headline).padding(.horizontal, 12).padding(.top, 8)
            Text("A file assigned to a slot is used by every program here that uses that slot (for U48–U55, by programs from before 2025). In any other factory slot it replaces the factory table; the report after packing lists those.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            Table(st.contentFiles) {
                // Most important first: what the file is, its slot, and whether anything uses it.
                TableColumn("File") { (f: ContentFile) in Text(f.url.lastPathComponent).lineLimit(1).help(f.url.path) }
                    .width(min: 120, ideal: 170)
                TableColumn("Name") { (f: ContentFile) in
                    HStack(spacing: 4) {
                        Text(st.displayName(f)).lineLimit(1).help(st.contentNames[f.id] != nil ? "Was \(f.name)" : f.name)
                        NameLengthNote(name: st.displayName(f))
                    }
                }
                    .width(min: 90, ideal: 150)
                TableColumn("Slot") { (f: ContentFile) in SlotPickerCell(state: st, file: f) }
                    .width(min: 110, ideal: 120)
                TableColumn("Used by") { (f: ContentFile) in UsageCell(state: st, file: f, note: unused[f.id]) }
                    .width(min: 200, ideal: 320)
                TableColumn("Type") { (f: ContentFile) in Text(f.kindLabel).foregroundStyle(.secondary).lineLimit(1).help(f.kindLabel) }
                    .width(min: 150, ideal: 170)
                TableColumn("") { (f: ContentFile) in
                    Button { st.removeContent(f.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove this file from the list")
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

    /// User slots first (the usual case), then the factory slots after a divider.
    private var userSlots: [SourceRef] {
        if file.isSample { return (0...SourceRef.sMax).map { SourceRef.s($0) } }
        if file.isPTable { return (SourceRef.factoryPCount..<SourceRef.pCount).map { SourceRef.p($0) } }
        return (SourceRef.factoryUCount..<SourceRef.uCount).map { SourceRef.u($0) }
    }
    private var factorySlots: [SourceRef] {
        if file.isSample { return [] }
        if file.isPTable { return (0..<SourceRef.factoryPCount).map { SourceRef.p($0) } }
        return (0..<SourceRef.factoryUCount).map { SourceRef.u($0) }
    }

    var body: some View {
        Picker("", selection: Binding<SourceRef?>(
            get: { file.slot },
            set: { state.setSlot(file.id, $0) }
        )) {
            Text("No slot").tag(SourceRef?.none)
            ForEach(userSlots, id: \.self) { s in Text(s.label).tag(SourceRef?.some(s)) }
            if !factorySlots.isEmpty {
                Divider()
                ForEach(factorySlots, id: \.self) { s in
                    Text("\(s.label)  \(state.slotName(s))  (factory)").tag(SourceRef?.some(s))
                }
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
                    Button("Point a program here…") { state.repointRequest = .init(fileID: file.id) }
                        .buttonStyle(.link)
                        .help("Choose a program and the oscillators that should play this file")
                }
            }
        } else {
            let n = state.programs.filter { p in state.plan(for: p).rows.contains { $0.choice == .file(file.id) } }.count
            Text("\(n) program\(n == 1 ? "" : "s")").foregroundStyle(.secondary)
        }
    }
}
