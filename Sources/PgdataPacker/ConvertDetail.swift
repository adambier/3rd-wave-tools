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

/// Below the Wavetables table: a read-only preview of the selected table, on the under-page
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
                // The preview lays itself out in the pane's width (the pictures and the facts
                // column share it; see ConvertItemPreview) and scrolls when the pane is too short
                // for it, so nothing is cut off at any size of the window or the split.
                ScrollView {
                    ConvertItemPreview(state: state, item: chosen[0])
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
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

/// For several selected tables: how many can't be converted yet and how many change on the way.
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
            Label("\(blocked) can’t be converted yet (see the Input column)", systemImage: "exclamationmark.octagon.fill")
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
            Text(title).font(.headline).lineLimit(1).help(title)
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
                        .help("Was \u{201C}\(item.table.name)\u{201D} in the file; renamed here")
                }
                Spacer()
                Button("Show Input File in Finder") { Panels.reveal(item.location.url) }.buttonStyle(.link)
                    .help("Show the file this table was read from in the Finder")
            }
            // The facts column takes up to 340 points and gives way down to 200 in a narrow
            // pane; the pictures take the width that is left, however little, and their text
            // wraps. The pane scrolls (see ConvertDetailPane) when the two are taller than it.
            // A table that can't be drawn yet (no frame size) has no pictures, and its facts,
            // which then say what to do, take the whole width.
            if item.table.wavetable(frameSize: item.frameSize) != nil {
                HStack(alignment: .top, spacing: 20) {
                    ConvertOverviewPair(state: state, item: item)
                        .frame(minWidth: 120, maxWidth: .infinity, alignment: .topLeading)
                    ConvertPreviewFacts(state: state, item: item)
                        .frame(minWidth: 200, idealWidth: 300, maxWidth: 340, alignment: .topLeading)
                }
            } else {
                ConvertPreviewFacts(state: state, item: item)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The facts about one table: its file and format, its frame size and what that rests on, its
/// interpolation, and what converting does.
struct ConvertPreviewFacts: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    /// The space between blocks (file, Input, Interpolation, Output) and, within a block,
    /// between its lines: one rhythm for the whole column.
    static let blockSpacing: CGFloat = 12
    static let lineSpacing: CGFloat = 3

    /// "64 frames × 2,048 samples", or what is missing.
    private var inputValue: String {
        guard let n = item.frameSize, let frames = item.frameCount else {
            return item.frameSize == nil ? "No frame size. Choose one in the Input column." : item.sizeDescription
        }
        return "\(frames) frame\(frames == 1 ? "" : "s") × \(ConvertPlan.formatCount(n)) samples"
    }

    /// Where the size comes from; for an assumed size, also where to change it.
    private var inputDetail: String {
        item.sizeSource == .guessed || item.sizeSource == .likely
            ? item.basisDescription + " If it sounds wrong, choose another size in the Input column."
            : item.basisDescription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.blockSpacing) {
            Text("\(item.sourceDescription) · \(item.location.url.path)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(([item.location.url.path] + item.alsoIn.map { "Also: " + $0.url.path }).joined(separator: "\n"))
            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                ConvertFactBlock(label: "Input", value: inputValue, detail: inputDetail, alert: item.frameSize == nil)
                if item.sizeIsStated && !item.frameSizeAlternatives.isEmpty {
                    ConvertSizeOverrideLink(state: state, item: item)
                }
            }
            ConvertFactBlock(label: "Interpolation", value: item.interpolationDescription, detail: nil, alert: false)
                .help("Whether a synth interpolates between frames as the table is swept, and how: crossfade (it blends neighbouring frames), spectral (it blends their harmonics), or none (no interpolation: it steps from frame to frame). Some files say which; most synths set it on the oscillator instead.")
            ConvertWhatHappens(state: state, item: item)
        }
        .textSelection(.enabled)
    }
}

/// One block of the facts: a small label, the value, and a line of detail under it.
struct ConvertFactBlock: View {
    let label: String
    let value: String
    let detail: String?
    /// Whether the value is a problem to act on (drawn in red).
    let alert: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ConvertPreviewFacts.lineSpacing) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(alert ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Change…" under the Input block when the file states its frame size: the override, which the
/// Input column does not offer for a stated size (it is rarely right), opens the same chooser
/// with the file's own size first and a sentence on when another is the right one. Once a size
/// is chosen, the column's chooser is active too, and choosing the file's own size again clears
/// the override.
struct ConvertSizeOverrideLink: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    @State private var choosing = false

    private var basis: String {
        let own = item.table.frameSize.map(ConvertPlan.formatCount) ?? "?"
        return "The file specifies \(own) samples per frame. Choose another size only if each frame shows more than one cycle, or part of one; the file's own size is right for nearly every file."
    }

    var body: some View {
        Button("Change…") { choosing.toggle() }
            .buttonStyle(.link)
            .font(.caption)
            .help("Override the frame size the file specifies (rarely needed)")
            .popover(isPresented: $choosing, arrowEdge: .bottom) {
                ConvertSizePopover(state: state, item: item, sizes: item.frameSizeAlternatives, basis: basis)
            }
    }
}

/// The table's frames stacked front to back, as the synths draw them: the input as read, with
/// its own interpolation, and beside it what the destination gets (the preview read back from
/// the bytes the writer made), with the interpolation the file records. The Frame slider under
/// them sweeps through the table: the frame at the slider lights up in both stacks, and a third
/// picture draws that cycle large, input and result together (see `ConvertSweepView`); moving
/// the pointer across a picture moves the slider too. Listen plays the cycle at the slider
/// (`AudioPreview`) at the pitch beside it. The pictures share the width they are given, however
/// narrow, and have a set height (see `ConvertOverview`).
struct ConvertOverviewPair: View {
    @ObservedObject var state: AppState
    @ObservedObject private var preview = AudioPreview.shared
    let item: ConvertPlan.Item
    /// The slider's place through the table, 0 (first frame) to 1 (last).
    @State private var position: Double = 0

    var body: some View {
        let plan = state.convertPlan
        if let source = item.table.wavetable(frameSize: item.frameSize) {
            let result = state.convertPreviews.resultFrames(item, in: plan)
            let resultInterpolation = plan.interpolationRecorded(for: item)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    ConvertOverview(frames: source.frames,
                                    caption: "Input · \(source.frameCount) × \(ConvertPlan.formatCount(source.frameSize))",
                                    interpolation: item.table.interpolation,
                                    unstatedLegend: "interpolation not stated",
                                    tint: WavetableStackCanvas.sourceColor,
                                    position: $position)
                    if let result, let first = result.first {
                        ConvertOverview(frames: result,
                                        caption: "\(plan.preset.shortTitle) · \(result.count) × \(ConvertPlan.formatCount(first.count))",
                                        interpolation: resultInterpolation,
                                        unstatedLegend: "interpolation not stored in the file",
                                        tint: WavetableStackCanvas.resultColor,
                                        position: $position)
                    }
                    ConvertSweepView(source: source.frames, sourceInterpolation: item.table.interpolation,
                                     result: result, resultInterpolation: resultInterpolation,
                                     resultTitle: plan.preset.shortTitle, position: position)
                }
                .help("The table’s frames, front (first) to back (last): the input as read, and what the destination gets, read back from the file this page would write. Solid lines are the frames in the file (at most 64 are drawn, each reduced to the width of the picture). Coloured lines between them show the interpolation: crossfades are exact; spectral blends are an approximation and do not reproduce Serum’s or Vital’s own morphs. The Frame slider below, or the pointer over a picture, sweeps through the table; the third picture draws the cycle there.")
                ConvertSweepControls(position: $position, preview: preview,
                                     playing: result != nil ? "the \(plan.preset.shortTitle) output" : "the input")
            }
            .onChange(of: position) { _ in updatePlaying(source: source.frames, result: result, resultInterpolation: resultInterpolation) }
            .onChange(of: result) { (r: [[Float]]?) in updatePlaying(source: source.frames, result: r, resultInterpolation: resultInterpolation) }
            .onChange(of: item.id) { _ in updatePlaying(source: source.frames, result: result, resultInterpolation: resultInterpolation) }
            .onChange(of: preview.isPlaying) { (playing: Bool) in
                if playing { preview.play(cycleToPlay(source: source.frames, result: result, resultInterpolation: resultInterpolation)) }
            }
            .onDisappear { preview.stop() }
        }
    }

    /// The cycle Listen plays: the result's at the slider when there is a result (what the
    /// destination gets), else the input's.
    private func cycleToPlay(source: [[Float]], result: [[Float]]?, resultInterpolation: Interpolation?) -> [Float] {
        if let result, let point = WavetableSketch.fullCycle(at: position, in: result, interpolation: resultInterpolation) {
            return point.values
        }
        return WavetableSketch.fullCycle(at: position, in: source, interpolation: item.table.interpolation)?.values ?? []
    }

    private func updatePlaying(source: [[Float]], result: [[Float]]?, resultInterpolation: Interpolation?) {
        guard preview.isPlaying else { return }
        preview.update(cycleToPlay(source: source, result: result, resultInterpolation: resultInterpolation))
    }
}

/// Under the pictures: the Frame slider, the Listen button, and the pitch pop-up (piano keys
/// with their numbers and frequencies). `playing` names what Listen plays, for its tip.
struct ConvertSweepControls: View {
    @Binding var position: Double
    @ObservedObject var preview: AudioPreview
    let playing: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Frame").font(.caption).foregroundStyle(.secondary)
                Slider(value: $position, in: 0...1)
                    .controlSize(.small)
                    .frame(minWidth: 80)
                    .accessibilityLabel("Frame")
                    .accessibilityValue(Text("\(Int((position * 100).rounded())) percent through the table"))
                    .help("Sweep through the table: the frame here is drawn in pink in the pictures and large in the third; Listen plays it")
                Button {
                    // The toggle only flips the state; ConvertOverviewPair hands the cycle over
                    // when it sees `isPlaying` change, so the two stay in step.
                    if preview.isPlaying { preview.stop() } else { preview.play([]) }
                } label: {
                    Label(preview.isPlaying ? "Stop" : "Listen", systemImage: preview.isPlaying ? "stop.fill" : "play.fill")
                        .frame(minWidth: 58)
                }
                .controlSize(.small)
                .help(preview.isPlaying ? "Stop playing" : "Play the cycle at the slider from \(playing), at the pitch chosen, until stopped")
                Picker("Pitch", selection: $preview.pitch) {
                    ForEach(AudioPreview.pitches) { (key: PianoKey) in
                        Text(key.label).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .help("The pitch Listen plays at: a piano key with its number (A4 = key 49 = 440 Hz) and frequency")
            }
            if let problem = preview.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One stacked-frames picture, its caption, and a legend with colour swatches for its lines.
/// The picture is 130 points high (the pane scrolls when that is too much) and as wide as it
/// is given; the caption and legend wrap rather than being cut off. The pointer's place across
/// the picture, left (first frame) to right (last), moves `position`.
struct ConvertOverview: View {
    let frames: [[Float]]
    let caption: String
    /// The interpolation to draw between the stored frames; nil when nothing says.
    let interpolation: Interpolation?
    /// The words after "Frames in the file" when `interpolation` is nil.
    let unstatedLegend: String
    /// The table's colour: the source's (`WavetableStackCanvas.sourceColor`) or the result's
    /// (`resultColor`), the same in the cycle picture beside them.
    let tint: Color
    /// The Frame slider's place, 0…1; the pointer over the picture moves it and it stays.
    @Binding var position: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WavetableStackCanvas(frames: frames, interpolation: interpolation, tint: tint, highlight: position)
                .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130)
                .overlay(
                    GeometryReader { (geo: GeometryProxy) in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { (phase: HoverPhase) in
                                if case .active(let point) = phase, geo.size.width > 0 {
                                    position = min(max(point.x / geo.size.width, 0), 1)
                                }
                            }
                    }
                )
                // The caption and legend say what the picture shows; VoiceOver gets them below.
                .accessibilityHidden(true)
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            ConvertOverviewLegend(interpolation: interpolation, unstated: unstatedLegend, tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // One element: the caption ("Input · 64 × 2,048"), then the legend's lines.
        .accessibilityElement(children: .combine)
    }
}

/// The cycle at the pointer's place in the sweep, drawn large: the source's in the stored-frame
/// colour and the result's over it in the accent colour, both to one scale (full scale, or the
/// louder of the two when a table goes beyond it, so a table that was turned down shows
/// smaller). Under it, which frames each comes from ("Frame 12 of 64"; "Between frames 12 and
/// 13 (crossfade)"), from `WavetableSketch.cycle(at:in:interpolation:)`. (The pink line in the
/// stacks marks the slider's place; here the two tables need two colours of their own.)
struct ConvertSweepView: View {
    let source: [[Float]]
    let sourceInterpolation: Interpolation?
    let result: [[Float]]?
    let resultInterpolation: Interpolation?
    let resultTitle: String
    /// The Frame slider's place, 0…1.
    let position: Double

    var body: some View {
        let sourcePoint = WavetableSketch.cycle(at: position, in: source, interpolation: sourceInterpolation)
        let resultPoint = result.flatMap { WavetableSketch.cycle(at: position, in: $0, interpolation: resultInterpolation) }
        VStack(alignment: .leading, spacing: 3) {
            SweepCycleCanvas(source: sourcePoint?.values ?? [], result: resultPoint?.values)
                .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130)
                // The lines under it say which frames are drawn; VoiceOver gets those.
                .accessibilityHidden(true)
            Text("Cycle at the slider")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                if let sourcePoint {
                    ConvertSwatch(color: WavetableStackCanvas.sourceColor,
                                  text: "Input: " + WavetableSketch.sweepWords(sourcePoint, of: source.count, interpolation: sourceInterpolation))
                }
                if let resultPoint, let result {
                    ConvertSwatch(color: WavetableStackCanvas.resultColor,
                                  text: resultTitle + ": " + WavetableSketch.sweepWords(resultPoint, of: result.count, interpolation: resultInterpolation))
                }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // One element: the caption, then which frame of each table is drawn.
        .accessibilityElement(children: .combine)
    }
}

/// Two cycles over each other, to one scale: the source's and, when there is one, the result's,
/// in the colours of their stacks (`WavetableStackCanvas.sourceColor`, `resultColor`).
struct SweepCycleCanvas: View {
    let source: [Float]
    let result: [Float]?

    var body: some View {
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            let peak = max(1, (source + (result ?? [])).reduce(Float(0)) { max($0, abs($1)) })
            let amplitude = (size.height / 2 - 2) / CGFloat(peak)
            let base = size.height / 2
            // The centre line, for the scale.
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: base)); axis.addLine(to: CGPoint(x: size.width, y: base))
            context.stroke(axis, with: .color(Color.secondary.opacity(0.3)), lineWidth: 0.5)
            if source.count > 1 {
                context.stroke(WavetableStackCanvas.path(source, x0: 0, base: base, width: size.width, amplitude: amplitude),
                               with: .color(WavetableStackCanvas.sourceColor.opacity(result == nil ? 1 : 0.6)), lineWidth: 1.2)
            }
            if let result, result.count > 1 {
                context.stroke(WavetableStackCanvas.path(result, x0: 0, base: base, width: size.width, amplitude: amplitude),
                               with: .color(WavetableStackCanvas.resultColor), lineWidth: 1.2)
            }
        }
    }
}

/// The legend under a picture, one line per kind of line: a swatch and a few words for the
/// frames the file holds, and another for the in-betweens when there are any.
struct ConvertOverviewLegend: View {
    let interpolation: Interpolation?
    let unstated: String
    let tint: Color

    private var storedWords: String {
        guard let mode = interpolation else { return "Frames in the file · " + unstated }
        return mode == Interpolation.none ? "Frames in the file (the table steps between them)" : "Frames in the file"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ConvertSwatch(color: tint, text: storedWords)
            if interpolation == .crossfade {
                ConvertSwatch(color: WavetableStackCanvas.crossfadeColor(tint), text: "Crossfades")
            } else if interpolation == .spectral {
                ConvertSwatch(color: WavetableStackCanvas.spectralColor, text: "Spectral blends (approx.)")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// A short line of colour and a few words, which wrap in a narrow pane.
struct ConvertSwatch: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 14, height: 3)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Stored frames drawn as polylines stacked diagonally, the first in front, the farthest
/// fading, each reduced to about a value per two points of width. Stepped tables show the
/// frames as separate slices with nothing between. With a crossfade or spectral
/// interpolation, thinner lines in a second colour fill each gap (up to five per gap), the
/// stored frames thin to 24 and the stack is drawn closer together, so the fill reads as a
/// surface; the picture stays within about 150 lines. With `highlight` set (0 front to 1
/// back, the pointer's place in the sweep), the cycle at that depth is drawn over the stack in
/// the highlight colour: a stored frame, or the in-between the interpolation gives there.
struct WavetableStackCanvas: View {
    let frames: [[Float]]
    let interpolation: Interpolation?
    /// The colour of the stored frames: the table's own, so the source and the result keep
    /// their colours across the pictures (`sourceColor`, `resultColor`).
    var tint: Color = WavetableStackCanvas.sourceColor
    var highlight: Double? = nil

    /// The source's colour, in its stack and in the cycle picture.
    static let sourceColor = Color.primary
    /// The result's colour, in its stack and in the cycle picture.
    static let resultColor = Color.accentColor
    /// The colour of crossfade in-betweens: the table's own, fainter.
    static func crossfadeColor(_ tint: Color) -> Color { tint.opacity(0.55) }
    /// The colour of spectral in-betweens, whichever table they belong to.
    static let spectralColor = Color.purple
    /// The colour of the highlighted cycle: one the page uses for nothing else (orange is for
    /// warnings, purple for spectral blends, the accent colour for the result).
    static let highlightColor = Color.pink

    /// A line to draw: its depth in frames from the front, its values, and whether it is an
    /// in-between.
    private struct Line {
        var position: Double
        var values: [Float]
        var between: Bool
    }

    var body: some View {
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            let showsBetweens = interpolation == .crossfade || interpolation == .spectral
            let lines = WavetableStackCanvas.lines(frames, interpolation: interpolation, showsBetweens: showsBetweens, width: size.width)
            guard let last = lines.first?.position, last > 0 || lines.count == 1 else { return }
            // Closer together with in-betweens, so the lines merge into a surface.
            let depthX = size.width * (showsBetweens ? 0.22 : 0.3)
            let depthY = size.height * (showsBetweens ? 0.36 : 0.5)
            let waveWidth = size.width - depthX
            let amplitude = (size.height - depthY) / 2 - 1
            let betweenColor = interpolation == .spectral ? WavetableStackCanvas.spectralColor : WavetableStackCanvas.crossfadeColor(tint)
            for line in lines {
                let t: CGFloat = last > 0 ? CGFloat(line.position / last) : 0
                let x0 = depthX * t
                let base = size.height - amplitude - 1 - depthY * t
                let path = WavetableStackCanvas.path(line.values, x0: x0, base: base, width: waveWidth, amplitude: amplitude)
                let fade = 1 - 0.6 * Double(t)
                if line.between {
                    context.stroke(path, with: .color(betweenColor.opacity(0.6 * fade)), lineWidth: 0.6)
                } else {
                    context.stroke(path, with: .color(tint.opacity(fade)), lineWidth: showsBetweens ? 1 : 1.2)
                }
            }
            // The cycle at the pointer, over everything, at its depth in the stack. Taken from
            // the drawn (reduced) frames, so it sits exactly on them.
            if let highlight {
                let stored = lines.filter { !$0.between }.sorted { $0.position < $1.position }.map(\.values)
                if let point = WavetableSketch.cycle(at: highlight, in: stored, interpolation: interpolation, columns: stored.first?.count ?? 1) {
                    let t = CGFloat(highlight)
                    let base = size.height - amplitude - 1 - depthY * t
                    let path = WavetableStackCanvas.path(point.values, x0: depthX * t, base: base, width: waveWidth, amplitude: amplitude)
                    context.stroke(path, with: .color(WavetableStackCanvas.highlightColor), lineWidth: 1.6)
                }
            }
        }
    }

    /// The lines back to front: the stored frames (reduced) and the in-betweens, sorted by
    /// depth so the front ones are drawn last.
    private static func lines(_ frames: [[Float]], interpolation: Interpolation?, showsBetweens: Bool, width: CGFloat) -> [Line] {
        let columns = max(8, Int(width * 0.7 / 2))
        let budget = WavetableSketch.lineBudget(storedFrames: frames.count, showsBetweens: showsBetweens)
        let reduced = WavetableSketch.reduce(frames, maxFrames: budget.stored, columns: columns)
        var out: [Line] = reduced.enumerated().map { (pair: (offset: Int, element: [Float])) -> Line in
            Line(position: Double(pair.offset), values: pair.element, between: false)
        }
        for b in WavetableSketch.inBetweens(reduced, interpolation: interpolation, perGap: budget.perGap) {
            out.append(Line(position: b.position, values: b.values, between: true))
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
        VStack(alignment: .leading, spacing: ConvertPreviewFacts.lineSpacing) {
            Text("Output").font(.caption).foregroundStyle(.secondary)
            if plan.canConvert(item) {
                if let file = state.convertPreviews.preview(item, in: plan) {
                    ConvertNoteList(file: file, output: plan.expected(for: item))
                } else {
                    Label("The table can’t be converted; the report after converting says why.", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            } else if plan.status(item) == .needsFrameSize {
                // The Input block already says, in red, that no size could be estimated and where
                // to choose one, and what the file's length allows; here only what that means.
                Text("None until a frame size is chosen.").foregroundStyle(.secondary)
            } else {
                Label(plan.statusDescription(item), systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The output's size and file, and the writer's notes as bullets, or that nothing but the
/// format changes.
struct ConvertNoteList: View {
    let file: OutputFile
    let output: ConvertPlan.ExpectedResult?

    /// "64 frames × 2,048 samples".
    private var sizeLine: String? {
        output.map { "\($0.frameCountOut) frame\($0.frameCountOut == 1 ? "" : "s") × \(ConvertPlan.formatCount($0.frameSizeOut)) samples" }
    }

    /// "Written as “Pad.wt” in the WAVES folder.": the file the page will write, which can share
    /// the source file's name, so it is said to be the file written.
    private var fileLine: String {
        "Written as \u{201C}\(file.fileName)\u{201D}" + (file.folder.map { " in the \($0) folder" } ?? "") + "."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ConvertPreviewFacts.lineSpacing) {
            if let sizeLine { Text(sizeLine) }
            Text(fileLine)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if file.notes.isEmpty {
                Text("Only the file format changes.").font(.caption).foregroundStyle(.secondary)
            } else if file.notes.count == 1 {
                // One note is a sentence, not a list of one.
                Text(file.notes[0]).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The writer's notes, one to a paragraph, with a little air between them.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<file.notes.count, id: \.self) { (i: Int) in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text(file.notes[i]).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}
