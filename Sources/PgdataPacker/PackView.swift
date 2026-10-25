import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(PgdataFormats)
import PgdataFormats
#endif
#if canImport(PgdataPackerCore)
import PgdataPackerCore
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
                EmptyHint(title: "Drop programs and their wavetables or multisamples here",
                          detail: "Add .pro files and the .wt and .bin files they use; folders work too. Each program then shows what its oscillators play and which files will be embedded.")
            } else {
                HSplitView {
                    programList.frame(minWidth: 220, idealWidth: 260, maxWidth: 440)
                    VSplitView {
                        detail.frame(minHeight: 300)
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
        // Programs removed in any way (Remove All… asks in a sheet, so nothing runs after it here)
        // leave the selection; keep it to the programs that remain.
        .onChange(of: state.programs.map(\.id)) { (ids: [UUID]) in
            selection = selection.filter { (id: UUID) -> Bool in ids.contains(id) }
        }
        .sheet(item: $state.repointRequest) { req in RepointSheet(state: state, request: req) }
    }

    // Keyboard shortcuts for adding and packing are on the File menu (main.swift).
    private var controls: some View {
        HStack(spacing: 14) {
            Button("Add Files or Folders…") {
                state.add(urls: Panels.chooseFiles(message: "Choose .pro programs and the .wt and .bin files they use",
                                                   allowedExtensions: ["pro", "wt", "bin", "pgdata"]))
            }
            Button("Clean Up Names…") { state.showNameCleanup = true }
                .disabled(state.programs.isEmpty && state.contentFiles.isEmpty)
                .help("Propose tidier names for the programs and the files you added (e.g., slot numbers removed, title case). Factory wavetables keep their names.")
                .sheet(isPresented: $state.showNameCleanup) { NameCleanupSheet(state: state) }
            Spacer()
            Button("Remove Selected") { state.removePrograms(visibleSelection); selection = [] }
                .disabled(visibleSelection.isEmpty || state.isWorking)
                .help("Remove the selected programs from this list (the files are not touched)")
            Button("Remove All…") { state.removeAllPack() }
                .disabled((state.programs.isEmpty && state.contentFiles.isEmpty) || state.isWorking)
                .help("Remove every program and added file from this page (the files are not touched)")
            Button("Pack Selected…") { state.writeUnified(Array(visibleSelection)) }
                .disabled(visibleSelection.isEmpty || state.isWorking)
            Button("Pack All…") { state.writeUnified(state.programs.map(\.id)) }
                .disabled(state.programs.isEmpty || state.isWorking)
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
    }

    /// The selection without rows the filter hides (the list keeps those selected out of sight).
    private var visibleSelection: Set<UUID> { selection.intersection(shownPrograms.map(\.id)) }

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
            SearchField(text: $state.programFilter, placeholder: "Filter by name or location")
                .padding(.horizontal, 10).padding(.vertical, 6)
            Toggle("Show only programs needing attention", isOn: $state.onlyAttention)
                .toggleStyle(.checkbox).font(.caption)
                .padding(.horizontal, 10).padding(.bottom, 4)
                .help("Programs that can't be packed yet, or that carry a warning")
            PackSummaryLine(state: st, shown: shownPrograms.count)
            Divider()
            List(selection: $selection) {
                ForEach(shownPrograms) { item in
                    ProgramRow(state: st, item: item).tag(item.id)
                }
            }
            .onDeleteCommand { state.removePrograms(visibleSelection); selection = [] }
            .overlay {
                if state.programs.isEmpty {
                    ListPlaceholder(text: "No programs yet. Drop .pro files onto this page, or click Add Files or Folders…")
                } else if shownPrograms.isEmpty {
                    ListPlaceholder(text: "No programs match the filter.")
                }
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
            Text(state.programs.isEmpty ? "Add a program to see what it will pack" : "Select a program")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One line above the program list: how many programs there are (and are shown, when the
/// filter hides some), and how many can't be packed yet.
struct PackSummaryLine: View {
    @ObservedObject var state: AppState
    let shown: Int

    private var blocked: Int {
        state.programs.filter { (item: AppState.PackItem) -> Bool in
            if case .blocked = state.plan(for: item).verdict { return true }
            return false
        }.count
    }

    var body: some View {
        let total = state.programs.count
        HStack(spacing: 10) {
            Text(shown == total ? "\(total) program\(total == 1 ? "" : "s")" : "\(shown) of \(total) programs shown")
                .monospacedDigit()
            if blocked > 0 {
                Label("\(blocked) can't be packed yet", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .help("Programs that need a file that isn't here; select one to see which slot")
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.bottom, 4)
    }
}

struct ProgramRow: View {
    @ObservedObject var state: AppState
    let item: AppState.PackItem

    /// What the row's symbol means, for VoiceOver (the Pack page's own words for each verdict).
    private func meaning(_ verdict: PackPlan.Verdict) -> String {
        switch verdict {
        case .factoryOnly: return "Factory tables only, nothing to embed"
        case .embedsContent: return "Embeds wavetables or multisamples"
        case .blocked: return "Can't be packed yet"
        }
    }

    var body: some View {
        let verdict = state.plan(for: item).verdict
        HStack {
            Image(systemName: verdict.symbol).foregroundStyle(verdict.tint)
                .accessibilityLabel(meaning(verdict))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).help(item.name)
                Text((item.locationLabel.map { $0 + "  ·  " } ?? "") + item.url.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(item.url.path)
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
                    Text("was \u{201C}\(item.program.name)\u{201D}").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help("Was \u{201C}\(item.program.name)\u{201D} in the .pro file; renamed here")
                    Button { st.setProgramName(item.id, nil) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Restore the name from the .pro file")
                        .help("Restore the name from the .pro file")
                }
                NameLengthNote(name: item.name)
                if let loc = item.locationLabel { Text(loc).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                Spacer()
                Button("Show in Finder") { Panels.reveal(item.url) }.buttonStyle(.link)
            }
            PlanSummary(plan: plan)
            if let c = plan.conversion {
                Label(c, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            }
            if let note = plan.userSlotNote { UserSlotNoteBox(note: note) }
            ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, w in
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
            // Keeps a few rows visible however long the note above is; the table, which scrolls,
            // is what gives way when the pane is short.
            .frame(minHeight: 120, maxHeight: .infinity)
        }
        .padding(12)
        // Pinned to the top, so a pane too short for the content clips the table's lower rows, not
        // the name field and notes.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    Button(expanded ? "Hide" : "Why, and What to Do") { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
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
                Text("\(from) → \(row.ref.label)").monospacedDigit().foregroundStyle(Color.accentColor)
                Button { state.undoRepoints(itemID, to: row.ref) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Point back to \(from)")
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
            if let c = row.choice { Text(state.describe(c, for: row.ref)).lineLimit(1).help(state.describe(c, for: row.ref)) }
            else { Text("—").foregroundStyle(.secondary) }
        } else if row.choice == nil && canRepoint {
            // Nothing for this slot yet: pointing the oscillators elsewhere is the usual fix, so it
            // comes first and is what a click on the button does; the chevron shows the rest.
            Menu {
                Button("Choose What to Play…", action: repoint)
                if !row.options.isEmpty { Divider() }
                optionItems
            } label: {
                Text("Choose What to Play…").lineLimit(1).help("Choose What to Play…")
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
                    Button("Play Something Else…", action: repoint)
                }
            } label: {
                Text(row.choice.map { state.describe($0, for: row.ref) } ?? "Choose What to Play…").lineLimit(1)
                    .help(row.choice.map { state.describe($0, for: row.ref) } ?? "Choose What to Play…")
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
            Text("Added Wavetables and Samples").font(.headline).padding(.horizontal, 12).padding(.top, 8)
            Text("A file assigned to a slot is used by every program here that uses that slot, with two exceptions for factory slots. In U48–U55, a file is used only by programs from before 2025, when those were user slots; later programs keep the factory table unless you choose the file in their Plays menu. In any other factory slot, the file replaces the factory table, and the report after packing says where.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            Table(st.contentFiles) {
                // Most important first: what the file is, its slot, and whether anything uses it.
                TableColumn("File") { (f: ContentFile) in Text(f.url.lastPathComponent).lineLimit(1).help(f.url.path) }
                    .width(min: 120, ideal: 170)
                TableColumn("Name") { (f: ContentFile) in
                    HStack(spacing: 4) {
                        Text(st.displayName(f)).lineLimit(1)
                            .help(st.contentNames[f.id] != nil ? "Was \u{201C}\(f.name)\u{201D} in the file; renamed here" : f.name)
                        NameLengthNote(name: st.displayName(f))
                    }
                }
                    .width(min: 90, ideal: 150)
                TableColumn("Slot") { (f: ContentFile) in SlotPickerCell(state: st, file: f) }
                    .width(min: 110, ideal: 120)
                TableColumn("Used By") { (f: ContentFile) in UsageCell(state: st, file: f, note: unused[f.id]) }
                    .width(min: 200, ideal: 320)
                TableColumn("Type") { (f: ContentFile) in Text(f.kindLabel).foregroundStyle(.secondary).lineLimit(1).help(f.kindLabel) }
                    .width(min: 150, ideal: 170)
                TableColumn("") { (f: ContentFile) in
                    Button { st.removeContent(f.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(st.isWorking)
                        .accessibilityLabel("Remove \(f.url.lastPathComponent)")
                        .help("Remove this file from the list (the file is not touched)")
                }
                .width(28)
            }
            .overlay {
                if st.contentFiles.isEmpty {
                    ListPlaceholder(text: "No wavetables or samples yet. Drop .wt and .bin files onto this page, or click Add Files or Folders…")
                }
            }
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

    private var slot: Binding<SourceRef?> {
        Binding<SourceRef?>(get: { file.slot }, set: { (s: SourceRef?) in state.setSlot(file.id, s) })
    }

    var body: some View {
        // A pop-up button: the slots are values that exclude one another. The closed button shows
        // the chosen item's title (a factory slot's includes its table name).
        Picker("Slot", selection: slot) {
            Text("No Slot").tag(SourceRef?.none)
            ForEach(userSlots, id: \.self) { (s: SourceRef) in
                Text(s.label).monospacedDigit().tag(SourceRef?.some(s))
            }
            if !factorySlots.isEmpty {
                Divider()
                ForEach(factorySlots, id: \.self) { (s: SourceRef) in
                    Text("\(state.labelledSlot(s))  (factory)").monospacedDigit().tag(SourceRef?.some(s))
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Slot")
        .help(file.slot.map { $0.isFactorySlot ? "\($0.label): factory slot, \(state.slotName($0))" : "\($0.label): user slot" } ?? "Choose the slot this file is for")
    }
}

struct UsageCell: View {
    @ObservedObject var state: AppState
    let file: ContentFile
    let note: String?

    /// A few words for the cell; the full reason is the tooltip.
    private func short(_ note: String) -> String {
        if note.hasPrefix("Identical to factory") { return "Same as the factory table; not embedded" }
        if note.hasPrefix("Not used: another choice") { return "Not used: the slot plays something else" }
        if note.hasPrefix("Not used: the added programs") { return "Not used: the programs are from after the 2025 update" }
        return "Not used"
    }

    var body: some View {
        if let note {
            HStack(spacing: 6) {
                Label(short(note), systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1).help(note)
                if !file.isSample, !state.programs.isEmpty, !state.isFactoryCopy(file) {
                    Button("Point a Program Here…") { state.repointRequest = .init(fileID: file.id) }
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
