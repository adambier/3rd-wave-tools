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
    @State private var search = ""

    init(state: AppState, request: AppState.RepointRequest) {
        _state = ObservedObject(wrappedValue: state)
        self.request = request
        let item = request.itemID ?? state.selectedProgram ?? state.programs.first?.id
        _itemID = State(initialValue: item)
        let file = request.fileID.flatMap { id in state.contentFiles.first { $0.id == id } }
        _target = State(initialValue: file?.slot)
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
    }

    private var fileTargets: [Target] {
        state.contentFiles.compactMap { f in
            guard !f.isSample, let s = f.slot else { return nil }
            return Target(id: "f" + f.id.uuidString, ref: s, title: "\(s.label)  \(f.name)", detail: f.url.lastPathComponent)
        }
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
                    Button { target = t.ref } label: {
                        HStack {
                            Image(systemName: target == t.ref ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(target == t.ref ? Color.accentColor : Color.secondary)
                            Text(t.title).lineLimit(1)
                            Spacer()
                            Text(t.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Apply

    private var applyTitle: String {
        guard let t = target else { return "Point" }
        let n = picked.count
        return "Point \(n) oscillator\(n == 1 ? "" : "s") to \(t.isBuiltIn ? t.description : t.label)"
    }

    private func apply() {
        guard let id = itemID, let t = target else { return }
        state.repoint(id, positions: Array(picked), to: t)
        state.selectedProgram = id
        dismiss()
    }
}
