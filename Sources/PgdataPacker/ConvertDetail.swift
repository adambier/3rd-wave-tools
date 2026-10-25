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
/// wave at each size the file allows), its interpolation, and what converting does.
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

/// One table: its name, its frame size, its interpolation, and what converting does.
struct ConvertItemDetail: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConvertDetailHeader(state: state, item: item)
            ConvertFrameSizeSection(state: state, item: item)
            ConvertOverviewPair(state: state, item: item)
            ConvertBetweenFramesLine(item: item)
            ConvertWhatHappens(state: state, item: item)
        }
    }
}

/// The table's frames stacked front to back, as the synths draw them: the source as read, with
/// its own interpolation, and beside it what the destination gets (the preview read back from
/// the bytes the writer made), with the interpolation the file records.
struct ConvertOverviewPair: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    var body: some View {
        let plan = state.convertPlan
        if let source = item.table.wavetable(frameSize: item.frameSize) {
            let result = state.convertPreviews.resultFrames(item, in: plan)
            HStack(alignment: .top, spacing: 16) {
                ConvertOverview(frames: source.frames, tint: .secondary,
                                caption: "Source · \(source.frameCount) × \(ConvertPlan.formatCount(source.frameSize))",
                                interpolation: item.table.interpolation,
                                unstatedLegend: "Interpolation not stated; stored frames only.")
                if let result, let first = result.first {
                    ConvertOverview(frames: result, tint: .accentColor,
                                    caption: "\(plan.preset.shortTitle) · \(result.count) × \(ConvertPlan.formatCount(first.count))",
                                    interpolation: plan.interpolationRecorded(for: item),
                                    unstatedLegend: "Interpolation set on the synth; stored frames only.")
                }
            }
            .help("The table's frames, front (first) to back (last): the source as read, and what the destination gets, read back from the file Convert would write. Solid lines are stored frames (at most 64 are drawn, each reduced to the width of the picture). Faint lines show the interpolation between them: crossfades are exact; spectral blends are an approximation, since Serum's and Vital's exact morphs aren't published.")
        }
    }
}

/// One stacked-frames picture with its caption and a legend for the faint lines.
struct ConvertOverview: View {
    let frames: [[Float]]
    let tint: Color
    let caption: String
    /// The interpolation to draw between the stored frames; nil when nothing says.
    let interpolation: Interpolation?
    /// The legend when `interpolation` is nil.
    let unstatedLegend: String

    private var legend: String {
        guard let mode = interpolation else { return unstatedLegend }
        switch mode {
        case Interpolation.none: return "Stepped: frames play as stored."
        case .crossfade: return "Faint lines: crossfades between frames."
        case .spectral: return "Faint lines: spectral blends (approximate)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WavetableStackCanvas(frames: frames, tint: tint, interpolation: interpolation)
                .frame(maxWidth: 360, minHeight: 100, maxHeight: 100)
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(legend).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Stored frames drawn as polylines stacked diagonally, the first in front, the farthest
/// fading, each reduced to about a value per two points of width. With a crossfade or spectral
/// interpolation, faint thinner lines between neighbouring frames show the blends; the stored
/// frames then thin to 32 so the whole picture stays within about 120 lines.
struct WavetableStackCanvas: View {
    let frames: [[Float]]
    let tint: Color
    let interpolation: Interpolation?

    /// A line to draw: its depth in frames from the front, its values, and whether it is faint.
    private struct Line {
        var position: Double
        var values: [Float]
        var faint: Bool
    }

    var body: some View {
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            let lines = WavetableStackCanvas.lines(frames, interpolation: interpolation, width: size.width)
            guard let last = lines.first?.position, last > 0 || lines.count == 1 else { return }
            let depthX = size.width * 0.3
            let depthY = size.height * 0.5
            let waveWidth = size.width - depthX
            let amplitude = (size.height - depthY) / 2 - 1
            for line in lines {
                let t: CGFloat = last > 0 ? CGFloat(line.position / last) : 0
                let x0 = depthX * t
                let base = size.height - amplitude - 1 - depthY * t
                let path = WavetableStackCanvas.path(line.values, x0: x0, base: base, width: waveWidth, amplitude: amplitude)
                let fade = 1 - 0.7 * Double(t)
                context.stroke(path, with: .color(tint.opacity(line.faint ? 0.3 * fade : fade)),
                               lineWidth: line.faint ? 0.5 : 1)
            }
        }
    }

    /// The lines back to front: the stored frames (reduced) and the faint in-betweens, sorted
    /// by depth so the front ones are drawn last.
    private static func lines(_ frames: [[Float]], interpolation: Interpolation?, width: CGFloat) -> [Line] {
        let columns = max(8, Int(width * 0.7 / 2))
        let showsBetweens = interpolation == .crossfade || interpolation == .spectral
        let budget = WavetableSketch.lineBudget(storedFrames: frames.count, showsBetweens: showsBetweens)
        let reduced = WavetableSketch.reduce(frames, maxFrames: budget.stored, columns: columns)
        var out: [Line] = reduced.enumerated().map { (pair: (offset: Int, element: [Float])) -> Line in
            Line(position: Double(pair.offset), values: pair.element, faint: false)
        }
        for b in WavetableSketch.inBetweens(reduced, interpolation: interpolation, perGap: budget.perGap) {
            out.append(Line(position: b.position, values: b.values, faint: true))
        }
        return out.sorted { (a: Line, b: Line) -> Bool in a.position > b.position }
    }

    /// One frame as a polyline from `x0` across `width`, around the baseline `base`.
    static func path(_ values: [Float], x0: CGFloat, base: CGFloat, width: CGFloat, amplitude: CGFloat) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let p = CGPoint(x: x0 + step * CGFloat(i), y: base - CGFloat(v) * amplitude)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
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
        case .inFile, .fileName, .sidecar: return "Frame size: \(size) — \(item.table.frameSizeBasis)."
        case .markers: return "Frame size: \(size) — \(item.table.frameSizeBasis); less certain."
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

    /// The samples as points, one per horizontal point at most (the largest-magnitude sample of
    /// each column, so a peak is never skipped), scaled to the cycle's own peak.
    static func points(_ samples: [Float], width: CGFloat, height: CGFloat) -> [CGPoint] {
        guard !samples.isEmpty, width > 1, height > 1 else { return [] }
        let columns = max(2, min(samples.count, Int(width)))
        guard let values = WavetableSketch.reduce([samples], maxFrames: 1, columns: columns).first, values.count > 1 else { return [] }
        return values.enumerated().map { (pair: (offset: Int, element: Float)) -> CGPoint in
            CGPoint(x: width * CGFloat(pair.offset) / CGFloat(values.count - 1),
                    y: height / 2 - CGFloat(pair.element) * (height / 2 - 1))
        }
    }
}

/// "Interpolation: Crossfade", with what interpolation is on hover.
struct ConvertBetweenFramesLine: View {
    let item: ConvertPlan.Item
    var body: some View {
        HStack(spacing: 6) {
            Text("Interpolation:").foregroundStyle(.secondary)
            Text(item.interpolationDescription)
        }
        .help("How a synth moves from one frame to the next as the table is swept: none (it steps from frame to frame), crossfade (it blends neighbours), or spectral (it blends their harmonics). Some files say which; most synths set it on the oscillator instead.")
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
