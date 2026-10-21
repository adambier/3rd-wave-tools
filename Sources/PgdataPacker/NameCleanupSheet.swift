import SwiftUI
#if canImport(PgdataFormats)
import PgdataFormats
#endif

/// "Clean Up Names…": proposes tidier names for the programs and the added wavetables and
/// multisamples (never factory wavetables). Every change is shown and can be edited or unticked.
/// Names are applied when packing; the source files are not changed.
struct NameCleanupSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        let id: UUID
        let kind: String
        let current: String
        let isProgram: Bool
    }

    @State private var rules: NameCleaner
    @State private var keepText: String
    @State private var edited: [UUID: String] = [:]
    @State private var excluded = Set<UUID>()
    @State private var onlyChanges = true

    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
        _rules = State(initialValue: state.nameCleaner)
        _keepText = State(initialValue: state.nameCleaner.keepUppercase.joined(separator: ", "))
    }

    private var allRows: [Row] {
        state.programs.map { Row(id: $0.id, kind: "Program", current: $0.name, isProgram: true) }
        + state.contentFiles.filter { !state.isFactoryCopy($0) }.map { f in
            Row(id: f.id, kind: f.isSample ? "Multisample" : (f.isPTable ? "P wavetable" : "U wavetable"),
                current: state.displayName(f), isProgram: false)
        }
    }

    private func proposed(_ r: Row) -> String { edited[r.id] ?? rules.clean(r.current) }
    private func changes(_ r: Row) -> Bool { proposed(r) != r.current }
    private var rows: [Row] { allRows.filter { !onlyChanges || changes($0) || edited[$0.id] != nil } }
    private var toApply: [Row] { allRows.filter { changes($0) && !excluded.contains($0.id) } }
    private var anyRenamed: Bool { !state.contentNames.isEmpty || state.programs.contains { $0.newName != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clean up names").font(.title3).bold()
            Text("Names are applied to the .pgdata files you write. The .pro, .wt and .bin files are not changed, and factory wavetables are never renamed.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 18) {
                Toggle("Remove slot numbers (U48, S010, B05P003) at the start or end", isOn: $rules.stripSlots)
                Toggle("Underscores to spaces", isOn: $rules.underscoresToSpaces)
            }
            HStack(spacing: 18) {
                Toggle("Title case", isOn: $rules.titleCase)
                    .help("Only for names that are entirely upper or entirely lower case. Names that already mix cases keep their capitals.")
                Text("Keep upper case:")
                TextField("SM, FM, PWM…", text: $keepText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: keepText) { t in
                        rules.keepUppercase = t.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0).uppercased() }
                    }
                    .help("Words always kept in capitals. Words containing digits (JP8, OBX8) are always kept as they are.")
            }
            Toggle("Show only names that change", isOn: $onlyChanges)

            Table(rows) {
                TableColumn("") { (r: Row) in
                    Toggle("", isOn: Binding(
                        get: { !excluded.contains(r.id) },
                        set: { if $0 { excluded.remove(r.id) } else { excluded.insert(r.id) } }
                    ))
                    .labelsHidden()
                    .disabled(!changes(r))
                }
                .width(24)
                TableColumn("Kind") { (r: Row) in Text(r.kind).foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 95)
                TableColumn("Current") { (r: Row) in Text(r.current).lineLimit(1).help(r.current) }
                    .width(min: 140, ideal: 220)
                TableColumn("New name") { (r: Row) in
                    TextField("", text: Binding(get: { proposed(r) }, set: { edited[r.id] = $0 }))
                        .textFieldStyle(.plain)
                        .foregroundStyle(changes(r) ? Color.primary : Color.secondary)
                }
                .width(min: 160, ideal: 240)
                TableColumn("") { (r: Row) in lengthNote(proposed(r)) }
                    .width(min: 120, ideal: 200)
            }
            .frame(minHeight: 300)

            HStack {
                Button("Restore Original Names") {
                    state.contentNames = [:]
                    for p in state.programs { state.setProgramName(p.id, nil) }
                    edited = [:]
                }
                .disabled(!anyRenamed)
                .help("Undo every rename made here, for all programs and files")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename \(toApply.count)") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(toApply.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 520)
    }

    @ViewBuilder private func lengthNote(_ name: String) -> some View {
        if name.count > NameCleaner.fieldLimit {
            Label("Too long: cut to \(NameCleaner.fieldLimit)", systemImage: "xmark.octagon").foregroundStyle(.red)
        } else if name.count > NameCleaner.longestFactoryName {
            Label("Longer than any factory name (\(NameCleaner.longestFactoryName)); may not fit the display", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).lineLimit(1)
                .help("The synth's display limit is not known. Every factory program name is \(NameCleaner.longestFactoryName) characters or fewer.")
        } else {
            EmptyView()
        }
    }

    private func apply() {
        var n = 0
        for r in toApply {
            let new = String(proposed(r).prefix(NameCleaner.fieldLimit))
            if r.isProgram { state.setProgramName(r.id, new) } else { state.contentNames[r.id] = new }
            n += 1
        }
        state.nameCleaner = rules
        state.note("Renamed \(n) item\(n == 1 ? "" : "s") for packing.")
        dismiss()
    }
}
