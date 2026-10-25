import SwiftUI
import AppKit
#if canImport(PgdataFormats)
import PgdataFormats
#endif
#if canImport(WavetableFormats)
import WavetableFormats
#endif
#if canImport(PgdataPackerCore)
import PgdataPackerCore
#endif

/// Below the Convert table: how the selected table will be converted. With one table selected,
/// its name (editable), its frame size and where that came from (with a picture of the first
/// wave at each size the file allows), how it moves between frames, and what converting does.
struct ConvertDetailPane: View {
    @EnvironmentObject var state: AppState
    let selection: Set<UUID>

    /// The selected rows the table shows (a row the attention filter hides stays selected out
    /// of sight, as in Pack).
    private var chosen: [ConvertPlan.Item] {
        let plan = state.convertPlan
        return plan.items.filter { (item: ConvertPlan.Item) -> Bool in
            selection.contains(item.id) && (!state.convertOnlyAttention || plan.needsAttention(item))
        }
    }

    var body: some View {
        let chosen = self.chosen
        Group {
            if chosen.isEmpty {
                Text("Select a table to see how it will be converted.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if chosen.count == 1 {
                ScrollView {
                    ConvertItemDetail(state: state, item: chosen[0])
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .visibleScrollers()
            } else {
                ConvertSeveralDetail(items: chosen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "n tables selected", with how many are blocked and how many change on the way.
struct ConvertSeveralDetail: View {
    @EnvironmentObject var state: AppState
    let items: [ConvertPlan.Item]

    var body: some View {
        let plan = state.convertPlan
        let blocked = items.filter { plan.status($0).isBlocked }.count
        let changed = items.filter { (item: ConvertPlan.Item) -> Bool in
            guard let e = plan.expected(for: item) else { return false }
            return e.resizes || e.changesCount || e.scaledToFit
        }.count
        VStack(alignment: .leading, spacing: 6) {
            Text("\(items.count) tables selected").font(.title2)
            if blocked > 0 {
                Label("\(blocked) can't convert yet (see the Size column)", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            Text("\(changed) change\(changed == 1 ? "s" : "") in frame size, frame count, or level on the way; the rest change format only.")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One table: its name, its frame size, how it moves between frames, and what converting does.
struct ConvertItemDetail: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConvertDetailHeader(state: state, item: item)
            ConvertFrameSizeSection(state: state, item: item)
            ConvertBetweenFramesLine(item: item)
            ConvertWhatHappens(state: state, item: item)
        }
    }
}

/// The name as an editable field, Show in Finder, and where the identical copies are.
struct ConvertDetailHeader: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    var body: some View {
        let st = state
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TextField("Table name", text: Binding(
                get: { item.name },
                set: { (new: String) in st.convertPlan.rename(item.id, to: new) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.title2)
            .frame(maxWidth: 380)
            .help("The name the converted file gets (and, for a 3rd Wave table, the name inside it); the source file is not changed.")
            if item.newName != nil {
                Text("was \(item.table.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button { st.convertPlan.rename(item.id, to: nil) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help("Restore the name from the file")
            }
            if !item.alsoIn.isEmpty {
                Text("Also in: " + item.alsoIn.map(\.label).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(item.alsoIn.map { $0.url.path }.joined(separator: "\n"))
            }
            Spacer()
            Button("Show in Finder") { Panels.reveal(item.location.url) }.buttonStyle(.link)
        }
    }
}

/// "Frame size: 2,048 samples, guessed from the file's length", the explanation when that is a
/// guess or still open, and one button per size the file allows, each with a picture of the
/// first wave cut at that size.
struct ConvertFrameSizeSection: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    private var line: String {
        guard let n = item.frameSize else { return "Frame size: not stated. Choose one:" }
        let size = ConvertPlan.formatCount(n) + " samples"
        switch item.sizeSource {
        case .inFile: return "Frame size: \(size), stated in the file (\(item.table.frameSizeBasis))."
        case .fileName, .sidecar: return "Frame size: \(size), from the \(item.table.frameSizeBasis)."
        case .markers: return "Frame size: \(size), from loop or cue markers (\(item.table.frameSizeBasis)); less certain."
        case .guessed: return "Frame size: \(size), guessed from the file's length."
        case .yourChoice: return "Frame size: \(size), your choice."
        case .notStated: return "Frame size: \(size)."
        }
    }

    private var needsExplaining: Bool { item.needsFrameSize || item.isGuessed || item.chosenFrameSize != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line)
                .foregroundStyle(item.frameSize == nil ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if needsExplaining {
                Text("A wavetable file is one long run of samples; the frame size says where each wave starts and ends. If it's wrong, every wave is cut in the wrong place. The size that draws one smooth cycle is the right one.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ConvertSizeChoices(state: state, item: item)
        }
    }
}

/// The sizes the file allows as buttons with thumbnails (the current one highlighted); with the
/// size settled, one thumbnail of the first wave.
struct ConvertSizeChoices: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    var body: some View {
        let choices = item.frameSizeChoices
        if choices.isEmpty {
            if let n = item.frameSize, n > 0 {
                HStack(spacing: 6) {
                    WaveThumbnail(samples: Array(item.table.samples.prefix(n)), tint: .primary)
                    Text("first wave").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { (size: Int) in
                    ConvertSizeButton(state: state, item: item, size: size)
                }
            }
        }
    }
}

/// One size: the first wave cut at that size, and "64 × 128" under it.
struct ConvertSizeButton: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    let size: Int

    var body: some View {
        let chosen = item.frameSize == size
        let frames = item.table.samples.count / max(size, 1)
        Button { state.convertPlan.chooseFrameSize(item.id, size) } label: {
            VStack(spacing: 3) {
                WaveThumbnail(samples: Array(item.table.samples.prefix(size)), tint: chosen ? Color.accentColor : Color.primary)
                Text("\(frames) × \(ConvertPlan.formatCount(size))")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(chosen ? Color.accentColor : Color.primary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chosen ? Color.accentColor : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(chosen ? "The frame size used: \(frames) frames of \(ConvertPlan.formatCount(size)) samples"
                     : "Use \(ConvertPlan.formatCount(size)) samples per frame (\(frames) frames)")
    }
}

/// A small picture of one cycle (about 60 × 24 points), drawn from its samples.
struct WaveThumbnail: View {
    let samples: [Float]
    let tint: Color
    var width: CGFloat = 60
    var height: CGFloat = 24

    var body: some View {
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            let points = WaveThumbnail.points(samples, width: size.width, height: size.height)
            guard points.count > 1 else { return }
            var path = Path()
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            context.stroke(path, with: .color(tint), lineWidth: 1)
        }
        .frame(width: width, height: height)
    }

    /// The samples as points, one per horizontal pixel at most (the largest-magnitude sample of
    /// each column, so a peak is never skipped), scaled to the cycle's own peak.
    static func points(_ samples: [Float], width: CGFloat, height: CGFloat) -> [CGPoint] {
        guard !samples.isEmpty, width > 1, height > 1 else { return [] }
        let peak = max(samples.reduce(0) { max($0, abs($1)) }, 1e-6)
        let columns = max(2, min(samples.count, Int(width)))
        var out: [CGPoint] = []
        out.reserveCapacity(columns)
        for c in 0..<columns {
            let lo = samples.count * c / columns
            let hi = max(lo + 1, samples.count * (c + 1) / columns)
            var v: Float = 0
            for s in samples[lo..<min(hi, samples.count)] where abs(s) > abs(v) { v = s }
            let x = width * CGFloat(c) / CGFloat(columns - 1)
            let y = height / 2 - CGFloat(v / peak) * (height / 2 - 1)
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }
}

/// "Between frames: Crossfade", with what that means on hover.
struct ConvertBetweenFramesLine: View {
    let item: ConvertPlan.Item
    var body: some View {
        HStack(spacing: 6) {
            Text("Between frames:").foregroundStyle(.secondary)
            Text(item.interpolationDescription)
        }
        .help("How the source file says to move between frames. Most synths set this on the oscillator instead.")
    }
}

/// What converting the table does, from the writer's own notes for it.
struct ConvertWhatHappens: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    var body: some View {
        let plan = state.convertPlan
        VStack(alignment: .leading, spacing: 4) {
            Text("What converting does").font(.headline)
            if plan.canConvert(item) {
                if let file = state.convertPreviews.preview(item, in: plan) {
                    ConvertNoteList(file: file)
                } else {
                    Label("The table can't be converted; the report after converting says why.", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            } else {
                Label(plan.statusDescription(item), systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The file written and the writer's notes as bullets, or that nothing but the format changes.
struct ConvertNoteList: View {
    let file: OutputFile
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Writes \u{201C}\(file.fileName)\u{201D}" + (file.folder.map { " in \($0)" } ?? ""))
                .foregroundStyle(.secondary)
            if file.notes.isEmpty {
                Text("Nothing changes but the format.")
            } else {
                ForEach(0..<file.notes.count, id: \.self) { (i: Int) in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(file.notes[i]).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}
