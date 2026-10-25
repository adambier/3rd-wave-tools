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

/// Below the Convert table: a read-only preview of the selected table, on the under-page
/// background so it reads as output rather than as a place to edit. The source and the result
/// are drawn frame by frame on the left; on the right, where the table came from, its frame size
/// and interpolation, and what converting it does. Names and frame sizes are edited in the table
/// above; the destination and its options, on the right, apply to every table to convert.
struct ConvertDetailPane: View {
    @EnvironmentObject var state: AppState
    let selection: Set<UUID>

    /// The selected rows the table shows (a row the filter hides stays selected out of sight,
    /// as in Pack).
    private var chosen: [ConvertPlan.Item] {
        let plan = state.convertPlan
        let filtering = state.convertOnlyAttention && plan.blockedCount > 0
        return plan.items.filter { (item: ConvertPlan.Item) -> Bool in
            selection.contains(item.id) && (!filtering || plan.needsAttention(item))
        }
    }

    var body: some View {
        let chosen = self.chosen
        Group {
            if chosen.count == 1 {
                ScrollView {
                    ConvertItemPreview(state: state, item: chosen[0])
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .visibleScrollers()
            } else {
                ConvertPreviewPlaceholder(items: chosen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// With no table or several selected: what to do, and for several, how many are blocked and how
/// many change on the way.
struct ConvertPreviewPlaceholder: View {
    @EnvironmentObject var state: AppState
    let items: [ConvertPlan.Item]

    var body: some View {
        let plan = state.convertPlan
        VStack(alignment: .leading, spacing: 6) {
            ConvertPreviewHeading(title: items.isEmpty ? "No table selected" : "\(items.count) tables selected")
            Text(items.isEmpty ? "Select a table to preview it." : "Select a single table to preview it.")
                .foregroundStyle(.secondary)
            if items.count > 1 {
                ConvertSeveralSummary(plan: plan, items: items)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// For several selected tables: how many can't convert yet and how many change on the way.
struct ConvertSeveralSummary: View {
    let plan: ConvertPlan
    let items: [ConvertPlan.Item]

    var body: some View {
        let blocked = items.filter { plan.status($0).isBlocked }.count
        let changed = items.filter { (item: ConvertPlan.Item) -> Bool in
            guard let e = plan.expected(for: item) else { return false }
            return e.resizes || e.changesCount || e.scaledToFit
        }.count
        if blocked > 0 {
            Label("\(blocked) can't convert yet (see the Size column)", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
        Text(ConvertSeveralSummary.changeSentence(changed: changed, of: items.count))
            .foregroundStyle(.secondary)
    }

    /// "12 of them change frame size, frame count, or volume; the rest change format only."
    static func changeSentence(changed: Int, of total: Int) -> String {
        if changed == 0 { return "None of them changes frame size, frame count, or volume; all change format only." }
        if changed == total { return "All of them change frame size, frame count, or volume." }
        return "\(changed) of them change\(changed == 1 ? "s" : "") frame size, frame count, or volume; the rest change format only."
    }
}

/// "Preview" in secondary type, then the title.
struct ConvertPreviewHeading: View {
    let title: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            Text(title).font(.headline).lineLimit(1)
        }
    }
}

/// One table: its name, then the pictures on the left and the facts on the right.
struct ConvertItemPreview: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ConvertPreviewHeading(title: item.name)
                if item.newName != nil {
                    Text("was \u{201C}\(item.table.name)\u{201D}").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Show in Finder") { Panels.reveal(item.location.url) }.buttonStyle(.link)
            }
            HStack(alignment: .top, spacing: 20) {
                ConvertOverviewPair(state: state, item: item)
                ConvertPreviewFacts(state: state, item: item)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// The facts about one table: its file and format, its frame size and what that rests on, its
/// interpolation, and what converting does.
struct ConvertPreviewFacts: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    private var frameSizeLine: String {
        guard let n = item.frameSize else { return "Frame size: not stated. Choose one in the Size column." }
        let size = "Frame size: \(ConvertPlan.formatCount(n)) samples"
        return item.sizeQualifier.map { size + " (\($0))." } ?? size + "."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(item.sourceDescription) · \(item.location.url.path)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(([item.location.url.path] + item.alsoIn.map { "Also: " + $0.url.path }).joined(separator: "\n"))
            Text(frameSizeLine)
                .foregroundStyle(item.frameSize == nil ? Color.red : Color.primary)
            Text(item.basisDescription)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Interpolation:").foregroundStyle(.secondary)
                Text(item.interpolationDescription)
            }
            .help("How a synth moves from one frame to the next as the table is swept: none (it steps from frame to frame), crossfade (it blends neighbours), or spectral (it blends their harmonics). Some files say which; most synths set it on the oscillator instead.")
            ConvertWhatHappens(state: state, item: item)
        }
        .textSelection(.enabled)
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
                .frame(minWidth: 160, maxWidth: 300, minHeight: 100, maxHeight: 100)
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

/// What converting the table does, from the writer's own notes for it.
struct ConvertWhatHappens: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    var body: some View {
        let plan = state.convertPlan
        VStack(alignment: .leading, spacing: 4) {
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
        .padding(.top, 4)
    }
}

/// The file written and the writer's notes as bullets, or that nothing but the format changes.
struct ConvertNoteList: View {
    let file: OutputFile
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output: \u{201C}\(file.fileName)\u{201D}" + (file.folder.map { " in \($0)" } ?? ""))
            if file.notes.isEmpty {
                Text("Nothing changes but the format.").foregroundStyle(.secondary)
            } else {
                ForEach(0..<file.notes.count, id: \.self) { (i: Int) in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(file.notes[i]).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}
