import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(ThirdWaveFormats)
import ThirdWaveFormats
#endif

/// What the user's synth has in each wavetable slot. Used to decide what a program will actually play,
/// and to offer "as on my synth" when packing. Sample slots are not tracked: sample memory changes
/// too often, so multisamples are always supplied on the Pack screen.
struct SlotsView: View {
    @EnvironmentObject var state: AppState
    enum Bank: String, CaseIterable, Identifiable { case u = "U wavetables", p = "P wavetables"; var id: String { rawValue } }
    @State private var bank: Bank = .u

    struct SlotRow: Identifiable {
        var id: String { ref.label }
        let ref: SourceRef
        let entry: SlotEntry
    }

    private var rows: [SlotRow] {
        let refs: [SourceRef]
        switch bank {
        case .u: refs = (0..<SourceRef.uCount).map { .u($0) }
        case .p: refs = (0..<SourceRef.pCount).map { .p($0) }
        }
        return refs.map { SlotRow(ref: $0, entry: state.profile.entry($0)) }
    }

    var body: some View {
        // Table cells get the state passed in: on recent macOS, cells hosted by a Table do not
        // reliably inherit environment objects (crash: "No ObservableObject of type AppState").
        let st = state
        VStack(alignment: .leading, spacing: 0) {
            FactoryFoldersBox().padding(12)
            Divider()
            HStack {
                Picker("", selection: $bank) {
                    ForEach(Bank.allCases) { b in Text(b.rawValue).tag(b) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                Spacer()
                Text("Drop .wt files whose names start with a slot (\"U48 …\") to assign them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Table(rows) {
                TableColumn("Slot") { (r: SlotRow) in Text(r.ref.label).monospacedDigit() }
                    .width(50)
                TableColumn("Contents") { (r: SlotRow) in SlotNameCell(state: st, row: r) }
                    .width(min: 160, ideal: 240)
                TableColumn("Where it comes from") { (r: SlotRow) in SlotSourceCell(row: r) }
                    .width(min: 160, ideal: 260)
                TableColumn("") { (r: SlotRow) in SlotActionsCell(state: st, ref: r.ref) }
                    .width(90)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            DropSupport.load(providers) { state.assignByFilename($0) }
            return true
        }
    }
}

struct SlotNameCell: View {
    @ObservedObject var state: AppState
    let row: SlotsView.SlotRow
    var body: some View {
        switch row.entry.state {
        case .factory:
            Text(state.factory.name(row.ref) ?? "Factory table").foregroundStyle(.secondary)
        case .unknown:
            Text("—").foregroundStyle(.secondary)
        case .file, .empty:
            TextField("Name on the synth", text: Binding(
                get: { row.entry.name },
                set: { state.renameSlot(row.ref, $0) }
            ))
            .textFieldStyle(.plain)
        }
    }
}

struct SlotSourceCell: View {
    let row: SlotsView.SlotRow
    var body: some View {
        switch row.entry.state {
        case .factory: Text("Factory").foregroundStyle(.secondary)
        case .unknown: Text("Unknown").foregroundStyle(.secondary)
        case .empty: Text("Empty / blank table").foregroundStyle(.secondary)
        case .file:
            let path = row.entry.path ?? ""
            HStack(spacing: 4) {
                Image(systemName: FileManager.default.fileExists(atPath: path) ? "doc" : "questionmark.folder")
                Text((path as NSString).lastPathComponent).lineLimit(1)
            }
            .help(FileManager.default.fileExists(atPath: path) ? path : "Missing: \(path)")
        }
    }
}

struct SlotActionsCell: View {
    @ObservedObject var state: AppState
    let ref: SourceRef
    var body: some View {
        Menu("Set…") {
            Button("Assign File…") { state.assignFile(to: ref) }
            if ref.isFactorySlot { Button("Factory") { state.setSlotState(ref, .factory) } }
            Button("Empty / blank") { state.setSlotState(ref, .empty) }
            Button("Unknown") { state.setSlotState(ref, .unknown) }
            if state.profile.entry(ref).state == .file, let p = state.profile.entry(ref).path {
                Divider()
                Button("Show File") { Panels.reveal(URL(fileURLWithPath: p)) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

struct FactoryFoldersBox: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        let p = state.factory.tables.keys.filter(\.isP).count
        let u = state.factory.tables.count - p
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Factory wavetables").font(.headline)
                Spacer()
                Button("Add Folder…") {
                    if let f = Panels.chooseFolder(prompt: "Use Folder", message: "Choose a folder of Groove's factory .wt files (P or U)") {
                        if !state.factoryFolders.contains(f) { state.factoryFolders.append(f) }
                    }
                }
            }
            if state.factoryFolders.isEmpty {
                Text("Not set. Point this at the folders of factory P and U wavetables from Groove's support page. Needed to embed factory tables and to recognise them when unpacking.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(state.factoryFolders, id: \.self) { f in
                HStack {
                    Image(systemName: "folder")
                    Text(f.path).lineLimit(1).truncationMode(.middle).font(.callout)
                    Spacer()
                    Button { state.factoryFolders.removeAll { $0 == f } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            if !state.factoryFolders.isEmpty {
                Text("Found \(u) of 56 factory U tables and \(p) of 36 factory P tables.")
                    .font(.caption).foregroundStyle(u == 56 && p == 36 ? Color.secondary : Color.orange)
            }
            ForEach(state.factory.problems.prefix(4), id: \.self) { s in
                Text(s).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
