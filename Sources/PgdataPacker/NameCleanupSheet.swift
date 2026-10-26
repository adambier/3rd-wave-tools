import SwiftUI
#if canImport(PgdataFormats)
import PgdataFormats
#endif
#if canImport(PgdataPackerCore)
import PgdataPackerCore
#endif

/// "Clean Up Names…": proposes tidier names (never for factory wavetables). Every change is shown
/// and can be edited or unchecked; the source files are not changed. On the Pack page it covers the
/// programs and the added wavetables and multisamples, and the names are applied when packing; on
/// the Wavetables page it covers the tables listed there, and the names are applied when converting.
struct NameCleanupSheet: View {
    /// The page the sheet renames for.
    enum Page { case pack, convert }

    @ObservedObject var state: AppState
    let page: Page
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

    init(state: AppState, page: Page = .pack) {
        _state = ObservedObject(wrappedValue: state)
        self.page = page
        _rules = State(initialValue: state.nameCleaner)
        _keepText = State(initialValue: state.nameCleaner.fixedSpellings.joined(separator: ", "))
    }

    private var allRows: [Row] {
        if page == .convert {
            return state.convertPlan.items.filter { $0.factorySlot == nil }.map {
                Row(id: $0.id, kind: $0.sourceDescription, current: $0.name, isProgram: false)
            }
        }
        return state.programs.map { Row(id: $0.id, kind: "Program", current: $0.name, isProgram: true) }
        + state.contentFiles.filter { !state.isFactoryCopy($0) }.map { f in
            Row(id: f.id, kind: f.isSample ? "Multisample" : (f.isPTable ? "P wavetable" : "U wavetable"),
                current: state.displayName(f), isProgram: false)
        }
    }

    private func proposed(_ r: Row) -> String { edited[r.id] ?? rules.clean(r.current) }
    private func changes(_ r: Row) -> Bool { proposed(r) != r.current }
    private var rows: [Row] { allRows.filter { !onlyChanges || changes($0) || edited[$0.id] != nil } }
    private var toApply: [Row] { allRows.filter { changes($0) && !excluded.contains($0.id) } }
    private var anyRenamed: Bool {
        page == .convert ? state.convertPlan.anyRenamed
                         : !state.contentNames.isEmpty || state.programs.contains { $0.newName != nil }
    }
    /// Whether names go into 3rd Wave name fields, so their length and characters matter.
    private var namesGoToThe3rdWave: Bool { page == .pack || state.convertPlan.preset.isThirdWave }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clean Up Names").font(.title3).bold()
            Text(page == .pack
                 ? "New names go into the .pgdata files you write; the source files are not changed. Factory wavetables keep their names."
                 : "New names apply to the converted files (and inside 3rd Wave tables). Source files and factory names stay as they are.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 18) {
                Toggle("Remove slot prefixes and suffixes (e.g., U48, B5-P003)", isOn: $rules.stripSlots)
                Toggle("Underscores to spaces", isOn: $rules.underscoresToSpaces)
            }
            HStack(spacing: 18) {
                Toggle("Title case", isOn: $rules.titleCase)
                    .help("Applied to names written entirely in capitals or entirely in lower case. Mixed-case names keep their capitals.")
                Text("Keep these spellings:")
                TextField("LFO, MIDI, LoFi…", text: $keepText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Spellings to keep")
                    .onChange(of: keepText) { t in
                        rules.fixedSpellings = t.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                    }
                    .help("Words written exactly as typed here (e.g., LFO, LoFi). Words with digits (e.g., JP8, TB303) are kept as they are anyway.")
            }
            Toggle("Show only changes", isOn: $onlyChanges)

            Table(rows) {
                TableColumn("") { (r: Row) in
                    Toggle("Rename \(r.current)", isOn: Binding(
                        get: { !excluded.contains(r.id) },
                        set: { if $0 { excluded.remove(r.id) } else { excluded.insert(r.id) } }
                    ))
                    .labelsHidden()
                    .disabled(!changes(r))
                }
                .width(24)
                // The preferred widths add up to well under the sheet's minimum width, or the
                // table grows a horizontal scroll bar for the few points it does not have.
                TableColumn("Kind") { (r: Row) in Text(r.kind).foregroundStyle(.secondary) }
                    .width(min: 90, ideal: 100)
                TableColumn("Current") { (r: Row) in Text(r.current).lineLimit(1).foregroundStyle(.secondary).help(r.current) }
                    .width(min: 140, ideal: 200)
                TableColumn("New Name") { (r: Row) in
                    TextField("New name", text: Binding(get: { proposed(r) }, set: { edited[r.id] = $0 }))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .help(proposed(r) + "\nEdit to change the proposed name")
                }
                .width(min: 160, ideal: 220)
                TableColumn("") { (r: Row) in
                    if page == .pack { NameLengthNote(name: proposed(r)) }
                    else if namesGoToThe3rdWave { ThirdWaveNameNote(name: proposed(r), compact: false) }
                }
                    .width(min: 100, ideal: 140)
            }
            .frame(minHeight: 300)

            HStack {
                Button("Undo All Renames") {
                    if page == .convert {
                        state.convertPlan.undoRenames()
                    } else {
                        state.contentNames = [:]
                        for p in state.programs { state.setProgramName(p.id, nil) }
                    }
                    edited = [:]
                }
                .disabled(!anyRenamed)
                .help(page == .pack ? "Undo every rename, for all programs and files" : "Undo every rename on the Wavetables page")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply \(toApply.count) Name\(toApply.count == 1 ? "" : "s")") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(toApply.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 520)
    }

    private func apply() {
        var n = 0
        for r in toApply {
            if page == .convert {
                // Not cut here: other destinations take longer names, and the 3rd Wave writer
                // shortens one that is too long and says so in its report.
                state.convertPlan.rename(r.id, to: proposed(r))
            } else {
                // Applied as the .pgdata will hold it, so the list shows what is packed.
                let new = NameField.fitted(proposed(r)).text
                if r.isProgram { state.setProgramName(r.id, new) } else { state.contentNames[r.id] = new }
            }
            n += 1
        }
        state.nameCleaner = rules
        state.note(page == .pack ? "Renamed \(n) item\(n == 1 ? "" : "s") for packing."
                                 : "Renamed \(n) table\(n == 1 ? "" : "s") for converting.")
        dismiss()
    }
}

/// Flags a name the 3rd Wave will not store as written, one label per change `NameField.fitted`
/// makes (the rule packing applies; see section 8 of FORMATS.md): too long for the 31-character
/// fields, letters outside Latin-1 written without their accents, other characters outside
/// Latin-1 written as "?", or control characters written as spaces. The tooltip says exactly
/// what is written.
struct NameLengthNote: View {
    let name: String
    var body: some View {
        let fit = NameField.fitted(name)
        ForEach(Array(fit.changes.enumerated()), id: \.offset) { _, change in
            switch change {
            case let .shortened(from, to):
                Label("Too long: shortened to \(NameField.displayLimit)", systemImage: "xmark.octagon").foregroundStyle(.red)
                    .help("The 3rd Wave’s name fields hold \(NameField.displayLimit) characters. This name is \(from); it is shortened to \u{201C}\(to)\u{201D}.")
            case let .accentsRemoved(from, to):
                let pairs = zip(from, to).map { "\u{201C}\($0)\u{201D} → \($1)" }
                Label(pairs.joined(separator: " "), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help("The 3rd Wave’s name fields cannot hold \(from.count == 1 ? "this letter" : "these letters"), so \(from.count == 1 ? "it is" : "they are") written without accents: \(pairs.joined(separator: ", ")). Edit the name to choose other letters.")
            case let .replacedWithQuestionMark(chars):
                let list = chars.map { "\u{201C}\($0)\u{201D}" }
                Label("\(list.joined(separator: " ")) → ?", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help("The 3rd Wave’s name fields cannot hold \(chars.count == 1 ? "this character" : "these characters"), so \(chars.count == 1 ? "it is" : "they are") written as \u{201C}?\u{201D}: \(list.joined(separator: ", ")). Replace \(chars.count == 1 ? "it" : "them") with plain equivalents (e.g., a hyphen for a dash, straight quotes) to keep the name as you typed it.")
            case .controlCharactersReplaced:
                Label("Line breaks → spaces", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help("Line breaks and other control characters in the name are written as spaces.")
            }
        }
    }
}
