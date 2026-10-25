import SwiftUI
#if canImport(PgdataFormats)
import PgdataFormats
#endif
#if canImport(PgdataPackerCore)
import PgdataPackerCore
#endif

/// "Change what oscillators play": choose oscillators of one program and the slot they should use.
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
    @State private var selectedID: String?
    @FocusState private var focus: Field?
    private enum Field { case list, filter }

    init(state: AppState, request: AppState.RepointRequest) {
        _state = ObservedObject(wrappedValue: state)
        self.request = request
        let item = request.itemID ?? state.selectedProgram ?? state.programs.first?.id
        _itemID = State(initialValue: item)
        var file = request.fileID.flatMap { id in state.contentFiles.first { $0.id == id } }
        var slots = state.suggestedSlots()
        // Opened from a wavetable slot that has nothing yet (e.g. Ghibli Bell's U57, or U48 in a
        // Dynamica program, which predates the factory U48): an added file without a slot can
        // simply be assigned to that slot, so the oscillators need not move. The suggestions map
        // unassigned files in name order to the user slots in order (01.wt → U56, 02.wt → U57), so
        // the file whose suggested slot is this one is preselected; failing that, the first
        // unassigned file no program uses, which is then offered for this slot.
        if let from = request.from, from.isWavetable,
           let it = state.programs.first(where: { $0.id == item }),
           state.plan(for: it).rows.first(where: { $0.ref == from })?.choice == nil {
            let candidates = state.contentFiles.filter { $0.slot == nil && $0.fits(from) }
            if file == nil {
                let unused = state.unusedContent
                file = candidates.first { slots[$0.id] == from }
                    ?? candidates.first { unused[$0.id] != nil }
                    ?? candidates.first
            }
            if let f = file, f.slot == nil { slots[f.id] = from }
        }
        _fileSlots = State(initialValue: slots)
        _target = State(initialValue: file.flatMap { $0.slot ?? slots[$0.id] })
        _targetFile = State(initialValue: file?.id)
        _selectedID = State(initialValue: file.map { "f" + $0.id.uuidString })
        var picks = Set<Int>()
        if let from = request.from, let it = state.programs.first(where: { $0.id == item }) {
            for (i, s) in it.effectiveProgram.sources.enumerated() where s == from { picks.insert(i) }
        }
        _picked = State(initialValue: picks)
    }

    private var item: AppState.PackItem? { itemID.flatMap { id in state.programs.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change what oscillators play").font(.title3).bold()
            Text("Check the oscillators to change, then select what they should play.")
                .foregroundStyle(.secondary)
            if request.itemID == nil {
                Picker("Program", selection: $itemID) {
                    ForEach(state.programs) { p in Text(p.name).tag(Optional(p.id)) }
                }
                .frame(maxWidth: 360)
                .onChange(of: itemID) { _ in picked = [] }
            } else if let item {
                Text(item.name).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                oscillatorList.frame(width: 330)
                targetList.frame(minWidth: 340)
            }
            .frame(height: 400)
            HStack {
                Text("Changes apply to the .pgdata only; the .pro file is left as it is.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(applyTitle) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((picked.isEmpty && !assignsOnly) || target == nil || item == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 720)
    }

    // MARK: Oscillators

    private func describe(_ r: SourceRef) -> String {
        r.isBuiltIn ? r.description : (r.isSample ? "\(r.label)  multisample" : state.labelledSlot(r))
    }

    @ViewBuilder private var oscillatorList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1  Oscillators to change").font(.headline)
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
                .visibleScrollers()
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
                var name = state.displayName(f)
                if name.uppercased().hasPrefix(s.label) { name = String(name.dropFirst(s.label.count)).trimmingCharacters(in: CharacterSet(charactersIn: " _-")) }
                return Target(id: "f" + f.id.uuidString, ref: s, title: "\(s.label)  \(name)", detail: f.url.lastPathComponent, file: f)
            }
            guard let s = fileSlots[f.id] else { return nil }
            return Target(id: "f" + f.id.uuidString, ref: s, title: state.displayName(f), detail: f.url.lastPathComponent, file: f)
        }
    }

    private var allTargets: [Target] { fileTargets + slotTargets + analogTargets }

    private func select(_ id: String?) {
        guard let id, let t = allTargets.first(where: { $0.id == id }) else { target = nil; targetFile = nil; return }
        target = t.ref
        targetFile = t.file?.id
    }

    /// Factory slots only: a user-slot table always comes from a file you added (listed above).
    private var slotTargets: [Target] {
        Oscillator.repointTargets.filter { !$0.isBuiltIn && $0.isFactorySlot }.map { r in
            Target(id: "s" + r.label, ref: r, title: state.labelledSlot(r), detail: "factory")
        }
    }
    private var analogTargets: [Target] {
        Oscillator.repointTargets.filter(\.isBuiltIn).map { r in
            Target(id: "a\(r.id)", ref: r, title: r.description, detail: "built-in wave")
        }
    }
    private func matches(_ t: Target) -> Bool {
        search.isEmpty || t.title.localizedCaseInsensitiveContains(search) || t.detail.localizedCaseInsensitiveContains(search)
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("2  What they should play").font(.headline)
            List(selection: $selectedID) {
                targetSection("Files you added", fileTargets.filter(matches))
                targetSection("Factory slots", slotTargets.filter(matches))
                targetSection("Analog waves", analogTargets.filter(matches))
            }
            .visibleScrollers()
            .focused($focus, equals: .list)
            .onChange(of: selectedID) { id in select(id) }
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter the list by slot or name (e.g., U56 or vowel)", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .filter)
            }
        }
        // Start with the list focused, not the filter field.
        .onAppear { DispatchQueue.main.async { focus = .list } }
    }

    @ViewBuilder private func targetSection(_ title: String, _ items: [Target]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { t in
                    HStack {
                        Text(t.title).lineLimit(1)
                        Spacer()
                        if let f = t.file, f.slot == nil {
                            Text("→ \(t.ref.label)").font(.caption).foregroundStyle(.secondary)
                                .help(t.ref == request.from
                                      ? "Will be assigned to \(t.ref.label), the slot this program uses."
                                      : "Given a free slot automatically; the 3rd Wave chooses the real slot on import.")
                        }
                        Text(t.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(t.id)
                }
            }
        }
    }

    // MARK: Apply

    private var applyTitle: String {
        guard let t = target else { return "Apply" }
        let n = picked.count
        let who = "\(n) oscillator\(n == 1 ? "" : "s")"
        if let fid = targetFile, let f = state.contentFiles.first(where: { $0.id == fid }) {
            if f.slot == nil, let from = request.from, t == from { return "Use \(state.displayName(f)) for \(from.label)" }
            return "Use \(state.displayName(f)) for \(who)"
        }
        return "Use \(t.isBuiltIn ? t.description : t.label) for \(who)"
    }

    /// Assigning an unassigned file to the slot the program already uses needs no oscillator ticked.
    private var assignsOnly: Bool {
        guard let fid = targetFile, let f = state.contentFiles.first(where: { $0.id == fid }), f.slot == nil,
              let from = request.from, target == from else { return false }
        return true
    }

    private func apply() {
        guard let id = itemID, var t = target else { return }
        if let fid = targetFile, let f = state.contentFiles.first(where: { $0.id == fid }), f.slot == nil {
            t = fileSlots[fid] ?? t
            state.setSlot(fid, t)
            state.note("\(f.url.lastPathComponent) assigned to \(t.label).")
        }
        if !picked.isEmpty { state.repoint(id, positions: Array(picked), to: t) }
        // Pointing at a file means that file, even when another file or the factory table holds its slot.
        if let fid = targetFile { state.setOverride(id, t, .file(fid)) }
        state.selectedProgram = id
        dismiss()
    }
}
