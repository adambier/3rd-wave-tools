import SwiftUI
#if canImport(ThirdWaveFormats)
import ThirdWaveFormats
#endif

/// "Point to another slot…": choose oscillators of one program and the slot they should use.
/// Opened from a source row (oscillators using that source pre-ticked) or from an unused content
/// file (its slot pre-selected; the program is chosen here). Only the .pgdata changes.
struct RepointSheet: View {
    @ObservedObject var state: AppState
    let request: AppState.RepointRequest
    @Environment(\.dismiss) private var dismiss
    @State private var itemID: UUID?
    @State private var picked = Set<Int>()
    @State private var target: SourceRef?
    /// Set when the target was chosen through an added file (rather than a bare slot).
    @State private var targetFile: UUID?
    /// Slot chosen in the sheet for each added file that is not yet assigned to one.
    @State private var fileSlots: [UUID: SourceRef] = [:]
    @State private var search = ""

    init(state: AppState, request: AppState.RepointRequest) {
        _state = ObservedObject(wrappedValue: state)
        self.request = request
        let item = request.itemID ?? state.selectedProgram ?? state.programs.first?.id
        _itemID = State(initialValue: item)
        let file = request.fileID.flatMap { id in state.contentFiles.first { $0.id == id } }
        var slots: [UUID: SourceRef] = [:]
        for f in state.contentFiles where !f.isSample && f.slot == nil {
            if let s = state.suggestedSlot(for: f) { slots[f.id] = s }
        }
        _fileSlots = State(initialValue: slots)
        _target = State(initialValue: file.flatMap { $0.slot ?? slots[$0.id] })
        _targetFile = State(initialValue: file?.id)
        var picks = Set<Int>()
        if let from = request.from, let it = state.programs.first(where: { $0.id == item }) {
            for (i, s) in it.effectiveProgram.sources.enumerated() where s == from { picks.insert(i) }
        }
        _picked = State(initialValue: picks)
    }

    private var item: AppState.PackItem? { itemID.flatMap { id in state.programs.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Point oscillators to another slot").font(.title3).bold()
            if request.itemID == nil {
                Picker("Program", selection: $itemID) {
                    ForEach(state.programs) { p in Text(p.program.name).tag(Optional(p.id)) }
                }
                .frame(maxWidth: 360)
                .onChange(of: itemID) { _ in picked = [] }
            } else if let item {
                Text(item.program.name).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                oscillatorList.frame(width: 330)
                targetList.frame(minWidth: 340)
            }
            .frame(height: 400)
            HStack {
                Text("Only the .pgdata written here changes; the .pro file is not modified.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(applyTitle) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty || target == nil || item == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 720)
    }

    // MARK: Oscillators

    private func describe(_ r: SourceRef) -> String {
        r.isBuiltIn ? r.description : (r.isSample ? "\(r.label)  multisample" : "\(r.label)  \(state.slotName(r))")
    }

    @ViewBuilder private var oscillatorList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Oscillators").font(.headline)
            if let item {
                let current = item.effectiveProgram.sources
                let original = item.program.sources
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<4, id: \.self) { part in
                            Text("Part \(part + 1)" + (part >= 2 ? " — plays only on 4-part models (24K, 24M)" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, part == 0 ? 0 : 6)
                            ForEach(0..<3, id: \.self) { osc in
                                let pos = part * 3 + osc
                                if pos < current.count {
                                    Toggle(isOn: Binding(
                                        get: { picked.contains(pos) },
                                        set: { if $0 { picked.insert(pos) } else { picked.remove(pos) } }
                                    )) {
                                        Text("Osc \(osc + 1): \(describe(current[pos]))"
                                             + (current[pos] != original[pos] ? "  (was \(original[pos].label))" : ""))
                                            .lineLimit(1)
                                    }
                                    .disabled(current[pos].isSample)
                                    .help(current[pos].isSample ? "Multisample oscillators are not repointed." : "")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Choose a program").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Targets

    private struct Target: Identifiable {
        let id: String
        let ref: SourceRef
        let title: String
        let detail: String
        var file: ContentFile? = nil
    }

    /// Added wavetable files. An unassigned one shows a slot picker; choosing it assigns that slot.
    private var fileTargets: [Target] {
        state.contentFiles.compactMap { f in
            guard !f.isSample else { return nil }
            if let s = f.slot {
                return Target(id: "f" + f.id.uuidString, ref: s, title: "\(s.label)  \(f.name)", detail: f.url.lastPathComponent, file: f)
            }
            guard let s = fileSlots[f.id] else { return nil }
            return Target(id: "f" + f.id.uuidString, ref: s, title: f.name, detail: f.url.lastPathComponent, file: f)
        }
    }

    private func isChosen(_ t: Target) -> Bool {
        if let f = t.file { return targetFile == f.id }
        return targetFile == nil && target == t.ref
    }

    private func choose(_ t: Target) {
        target = t.ref
        targetFile = t.file?.id
    }

    private func slotChoices(for f: ContentFile) -> [SourceRef] {
        f.isPTable ? (0..<SourceRef.pCount).map { SourceRef.p($0) } : (0..<SourceRef.uCount).map { SourceRef.u($0) }
    }
    private var slotTargets: [Target] {
        Oscillator.repointTargets.filter { !$0.isBuiltIn }.map { r in
            Target(id: "s" + r.label, ref: r, title: "\(r.label)  \(state.slotName(r))", detail: r.isFactorySlot ? "factory slot" : "")
        }
    }
    private var analogTargets: [Target] {
        Oscillator.repointTargets.filter(\.isBuiltIn).map { r in
            Target(id: "a\(r.id)", ref: r, title: r.description, detail: "built in")
        }
    }
    private func matches(_ t: Target) -> Bool {
        search.isEmpty || t.title.localizedCaseInsensitiveContains(search) || t.detail.localizedCaseInsensitiveContains(search)
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Point them to").font(.headline)
            TextField("Search slot or name (\"u56\", \"nost\")", text: $search).textFieldStyle(.roundedBorder)
            List {
                targetSection("Files you added", fileTargets.filter(matches))
                targetSection("Wavetable slots on your synth", slotTargets.filter(matches))
                targetSection("Analog shapes", analogTargets.filter(matches))
            }
        }
    }

    @ViewBuilder private func targetSection(_ title: String, _ items: [Target]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { t in
                    HStack {
                        Button { choose(t) } label: {
                            HStack {
                                Image(systemName: isChosen(t) ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(isChosen(t) ? Color.accentColor : Color.secondary)
                                Text(t.title).lineLimit(1)
                                Spacer()
                                Text(t.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if let f = t.file, f.slot == nil {
                            Picker("Slot", selection: Binding<SourceRef>(
                                get: { fileSlots[f.id] ?? t.ref },
                                set: { s in
                                    fileSlots[f.id] = s
                                    if targetFile == f.id { target = s }
                                }
                            )) {
                                ForEach(slotChoices(for: f), id: \.self) { s in
                                    Text(s.label + (s.isFactorySlot ? " (factory)" : "")).tag(s)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            .help("Not yet assigned to a slot: it will be assigned to this one")
                        }
                    }
                }
            }
        }
    }

    // MARK: Apply

    private var applyTitle: String {
        guard let t = target else { return "Point" }
        if let fid = targetFile, let f = state.contentFiles.first(where: { $0.id == fid }) {
            let n = picked.count
            return "Point \(n) oscillator\(n == 1 ? "" : "s") to \(f.name) (\(t.label))"
        }
        let n = picked.count
        return "Point \(n) oscillator\(n == 1 ? "" : "s") to \(t.isBuiltIn ? t.description : t.label)"
    }

    private func apply() {
        guard let id = itemID, var t = target else { return }
        if let fid = targetFile, let f = state.contentFiles.first(where: { $0.id == fid }), f.slot == nil {
            t = fileSlots[fid] ?? t
            state.setSlot(fid, t)
            state.note("\(f.url.lastPathComponent) assigned to \(t.label).")
        }
        state.repoint(id, positions: Array(picked), to: t)
        state.selectedProgram = id
        dismiss()
    }
}
