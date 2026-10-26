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

/// Under the Wavetables table, across the left side: a read-only preview of the selected table,
/// on the under-page background so it reads as output rather than as a place to edit. The
/// source and the result are drawn frame by frame on the left; on the right, where the table
/// came from, its frame size and interpolation, and what converting it does. Names and frame
/// sizes are edited in the table above; the destination and its options, in the right pane,
/// apply to every table converted.
struct ConvertDetailPane: View {
    @EnvironmentObject var state: AppState
    let selection: Set<UUID>
    /// The most height the pane may take (what leaves the destination below its minimum).
    let maxHeight: CGFloat
    /// The height the content asks for, measured as it lays out.
    @State private var contentHeight: CGFloat = 0

    /// The least the pane is given, whatever the window's height.
    static let minimumHeight: CGFloat = 120
    /// The height the pane keeps whatever is selected, so it does not grow and shrink as the
    /// selection or the Frame slider changes the text in it (Adam, 2026-10-26): room for the
    /// pictures with four lines of legend under them, and for the facts with three notes. Taller
    /// content, which is rare, still grows it (or scrolls it in a short window).
    static let preferredHeight: CGFloat = 320

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
        // The pane keeps `preferredHeight`, growing only for taller content, up to `maxHeight`:
        // a status display, not a pane to resize or scroll. Only in a short window does the
        // content exceed the room; it then scrolls, and a fade at the bottom edge shows there is
        // more.
        let height = min(max(contentHeight, Self.preferredHeight, Self.minimumHeight), maxHeight)
        let overflows = contentHeight > maxHeight + 0.5
        ScrollView {
            Group {
                if chosen.count == 1 {
                    ConvertItemPreview(state: state, item: chosen[0])
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    ConvertPreviewPlaceholder(items: chosen)
                }
            }
            .background(GeometryReader { (geo: GeometryProxy) in
                Color.clear.preference(key: ConvertDetailHeightKey.self, value: geo.size.height)
            })
        }
        .onPreferenceChange(ConvertDetailHeightKey.self) { (h: CGFloat) in contentHeight = h }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .bottom) {
            if overflows {
                LinearGradient(colors: [Color(nsColor: .underPageBackgroundColor).opacity(0), Color(nsColor: .underPageBackgroundColor)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 18)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The height the preview's content lays out at (`ConvertDetailPane`).
struct ConvertDetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
            Text(items.isEmpty ? "Select a table to preview it." : "Select a single table to preview it; the frame size of several can be set below.")
                .foregroundStyle(.secondary)
            if items.count > 1 {
                ConvertSeveralSummary(plan: plan, items: items)
                ConvertSeveralFrameSize(state: state, items: items)
                    .padding(.top, 6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// For several selected tables: one frame size for those whose file does not state one
/// (estimated, or open), from the sizes all of them allow. Select all (⌘A) and a folder
/// of unlabeled WAVs from one maker is settled in one choice. Tables whose file states a size
/// keep it (the preview's Override Frame Size… is for one table at a time). When no selected
/// table is adjustable, or no one size fits them all, a line says so instead.
struct ConvertSeveralFrameSize: View {
    @ObservedObject var state: AppState
    let items: [ConvertPlan.Item]

    var body: some View {
        let plan = state.convertPlan
        let ids = Set(items.map(\.id))
        let adjustable = plan.adjustableItems(in: ids)
        let sizes = ConvertPlan.commonFrameSizes(of: adjustable)
        let stated = items.count - adjustable.count
        VStack(alignment: .leading, spacing: 4) {
            if adjustable.isEmpty {
                // Nothing to set: every selected table takes its size from the file (the
                // preview's Override Frame Size… changes one at a time).
                Text("\(CountWords.all(items.count, "tables")) take their frame size from the file.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if sizes.isEmpty {
                Text("No one frame size fits \(CountWords.all(adjustable.count, "tables").lowercased()) whose size is estimated; set them in the Input column.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let shared = ConvertPlan.sharedFrameSize(of: adjustable)
                HStack(spacing: 8) {
                    Text(adjustable.count == items.count
                         ? "Frame size for \(CountWords.all(items.count, "tables").lowercased()):"
                         : (adjustable.count == 1 ? "Frame size for the one table whose size is estimated:"
                                                  : "Frame size for the \(adjustable.count) tables whose size is estimated:"))
                    Picker("Frame size", selection: Binding<Int>(
                        get: { shared ?? 0 },
                        set: { (size: Int) in if size != 0 { state.convertPlan.chooseFrameSize(size, forAll: ids) } })) {
                        if shared == nil { Text("Various").tag(0) }
                        ForEach(sizes, id: \.self) { (size: Int) in
                            Text("\(ConvertPlan.formatCount(size)) samples per frame").tag(size)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("One frame size for the selected tables whose size is estimated (not stated in the file); only the sizes every one of their lengths allows are offered. Each table’s Input column shows the result and can still be changed on its own.")
                }
                if stated > 0 {
                    Text(stated == 1 ? "1 table takes its frame size from the file and keeps it."
                                     : "\(stated) tables take their frame size from the file and keep it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// For several selected tables: how many can't be converted yet, and what converting does to
/// them, counted by kind of change (the Changes column holds each table's own).
struct ConvertSeveralSummary: View {
    let plan: ConvertPlan
    let items: [ConvertPlan.Item]

    var body: some View {
        let blocked = items.filter { plan.status($0).isBlocked }.count
        if blocked > 0 {
            Label("\(blocked) can’t be converted yet (see the Input column)", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
        Text(ConvertSeveralSummary.changeSentence(plan: plan, items: items))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Converting to a U table resizes 13 of the 13 tables (see the Changes column); 11 get fewer
    /// frames; 2 are attenuated." or "Converting changes only the file format of all 13 tables."
    static func changeSentence(plan: ConvertPlan, items: [ConvertPlan.Item]) -> String {
        let expected = items.compactMap { plan.expected(for: $0) }
        let resized = expected.filter(\.resizes).count
        let fewer = expected.filter { $0.changesCount && $0.frameCountGrows == false }.count
        let more = expected.filter { $0.changesCount && $0.frameCountGrows == true }.count
        let down = expected.filter(\.scaledToFit).count
        let total = items.count
        let kind = plan.preset.shortTitle
        let these = CountWords.all(total, "tables").lowercased()   // "all 13 tables", "both tables"
        if resized + fewer + more + down == 0 {
            return "Converting to \(kind) changes only the file format of \(these)."
        }
        func count(_ n: Int) -> String { n == total ? "all" : "\(n)" }
        var parts: [String] = []
        if resized > 0 { parts.append("resizes the frames of \(resized == total ? these : "\(resized) of the \(total) tables")") }
        if fewer > 0 { parts.append("\(count(fewer)) get fewer frames") }
        if more > 0 { parts.append("\(count(more)) get more frames") }
        if down > 0 { parts.append("\(count(down)) \(down == 1 ? "is" : "are") attenuated") }
        if resized == 0 { parts[0] = "changes \(these): " + parts[0] }
        return "Converting to \(kind) " + parts.joined(separator: "; ") + " (see the Changes column)."
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

/// One table: its name, then the pictures with the Frame slider under them on the left and the
/// facts on the right.
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
            // The pictures take the width that is left after the facts column (up to 460
            // points, down to 300 in a narrow window), three abreast; side by side the preview
            // stays short, and the pane scrolls (see ConvertDetailPane) only in a short window.
            // A table that can't be drawn yet (no frame size) has no pictures, and its facts,
            // which then say what to do, take the whole width.
            if item.table.wavetable(frameSize: item.frameSize) != nil {
                HStack(alignment: .top, spacing: 24) {
                    ConvertOverviewPair(state: state, item: item)
                        .frame(minWidth: 240, maxWidth: .infinity, alignment: .topLeading)
                    ConvertPreviewFacts(state: state, item: item)
                        .frame(minWidth: 300, idealWidth: 420, maxWidth: 460, alignment: .topLeading)
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

    /// Where the size comes from; for an estimated size, also where to change it.
    private var inputDetail: String {
        item.sizeSource == .guessed || item.sizeSource == .likely
            ? item.basisDescription + " If the frames look or sound wrong, choose another size in the Input column."
            : item.basisDescription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.blockSpacing) {
            Text("\(item.sourceDescription) · \(item.location.url.path)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(([item.location.url.path] + item.alsoIn.map { "Also: " + $0.url.path }).joined(separator: "\n"))
            // Input and Interpolation side by side: the one is a sentence or two, the other a
            // word, and a row keeps the pane short.
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: Self.lineSpacing) {
                    ConvertFactBlock(label: "Input", value: inputValue, detail: inputDetail, alert: item.frameSize == nil)
                    if item.sizeIsStated && !item.frameSizeAlternatives.isEmpty {
                        ConvertSizeOverrideLink(state: state, item: item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                ConvertFactBlock(label: "Interpolation", value: item.interpolationDescription, detail: nil, alert: false)
                    .frame(width: 130, alignment: .topLeading)
                    .help("Whether a synth interpolates between frames as the table is swept, and by which method: crossfade (it blends neighboring frames) or spectral (it blends their harmonics); none means no interpolation (it steps from frame to frame). Some files say which; most synths set it on the oscillator instead.")
            }
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

/// "Override Frame Size…" under the Input block when the file states its frame size: the override, which the
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
        return "The file specifies \(own) samples per frame. Choose another size only if each frame shows more than one cycle, or part of one; the file’s own size is right for nearly every file."
    }

    var body: some View {
        Button("Override Frame Size…") { choosing.toggle() }
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
/// picture draws that cycle large, input and result together (see `ConvertSweepView`). (The
/// pointer over a picture used to move the sweep too; it went when the slider came, since a
/// pointer leaving the slider crossed the pictures and moved it.) Listen plays the cycle at the slider
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
            // The result comes from the cache, or a moment later from the background queue (the
            // input is drawn at once; the result's place says it is being converted).
            let converted = state.convertPreview(item)
            let result = converted?.frames
            // What the destination's synth plays, for the result's in-betweens and Listen: the
            // 3rd Wave's wavetable smoothing by default (a U table blends, a P table steps).
            let resultInterpolation = plan.interpolationPlayed(for: item)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    ConvertOverview(frames: source.frames,
                                    caption: "Input · \(source.frameCount) × \(ConvertPlan.formatCount(source.frameSize))",
                                    interpolation: item.table.interpolation,
                                    unstatedLegend: "interpolation not stated",
                                    tint: WavetableStackCanvas.sourceColor,
                                    position: position)
                    if let result, let first = result.first {
                        ConvertOverview(frames: result,
                                        caption: "\(plan.preset.shortTitle) · \(result.count) × \(ConvertPlan.formatCount(first.count))",
                                        interpolation: resultInterpolation,
                                        unstatedLegend: "interpolation set in the synth",
                                        interpolationNote: ConvertOverviewPair.interpolationNote(for: plan.preset),
                                        tint: WavetableStackCanvas.resultColor,
                                        position: position)
                    } else if converted == nil {
                        ConvertPreviewPending(caption: plan.preset.shortTitle)
                    }
                    ConvertSweepView(source: source.frames, sourceInterpolation: item.table.interpolation,
                                     result: result, resultInterpolation: resultInterpolation,
                                     resultTitle: plan.preset.shortTitle, position: position)
                }
                .help("The table’s frames, front (first) to back (last): the input as read, and what the destination gets, read back from the file this page would write. Solid lines are the frames in the file (at most 64 are drawn, 24 when the interpolation is drawn between them, each reduced to the width of the picture). Colored lines between them show the interpolation: crossfades are exact; spectral blends are an approximation and do not reproduce Serum’s or Vital’s own morphs. The Frame slider below sweeps through the table; the third picture draws the cycle there.")
                ConvertSweepControls(position: $position, preview: preview,
                                     playing: result != nil ? "the \(plan.preset.shortTitle) output" : "the input",
                                     cycle: { cycleToPlay(source: source.frames, result: result, resultInterpolation: resultInterpolation) })
            }
            .onChange(of: position) { _ in updatePlaying(source: source.frames, result: result, resultInterpolation: resultInterpolation) }
            .onChange(of: result) { (r: [[Float]]?) in updatePlaying(source: source.frames, result: r, resultInterpolation: resultInterpolation) }
            // The Options' interpolation changes what plays between frames without changing
            // the frames themselves, so it is watched on its own.
            .onChange(of: resultInterpolation) { (i: Interpolation?) in updatePlaying(source: source.frames, result: result, resultInterpolation: i) }
            .onChange(of: item.id) { _ in updatePlaying(source: source.frames, result: result, resultInterpolation: resultInterpolation) }
            .onDisappear { preview.stop() }
        }
    }

    /// Why the result is drawn and played with its interpolation when its file records none:
    /// for the 3rd Wave, what its wavetable smoothing does by default (checked on an 8M;
    /// FORMATS.md section 5.1; `ConvertPlan.interpolationPlayed(for:)`). Nil for the others.
    static func interpolationNote(for preset: OutputPreset) -> String? {
        switch preset {
        case .thirdWaveU: return "wavetable smoothing, on by default on the 3rd Wave, taken as a crossfade"
        case .thirdWaveP: return "wavetable smoothing is off by default on the 3rd Wave"
        default: return nil
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
/// with their frequencies). `playing` names what Listen plays, for its tip; `cycle`
/// gives the cycle to play when Listen is pressed.
struct ConvertSweepControls: View {
    @Binding var position: Double
    @ObservedObject var preview: AudioPreview
    let playing: String
    let cycle: () -> [Float]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Frame").font(.caption).foregroundStyle(.secondary)
                Slider(value: $position, in: 0...1)
                    .controlSize(.small)
                    .frame(minWidth: 80)
                    .accessibilityLabel("Frame")
                    .accessibilityValue(Text("\(Int((position * 100).rounded())) percent through the table"))
                    .help("Sweep through the table: the frame at the slider is drawn in pink in the pictures and large in the third; Listen plays it")
                Button {
                    if preview.isPlaying { preview.stop() } else { preview.play(cycle()) }
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
                .help("The pitch Listen plays at: a piano key and its frequency (A4 is 440 Hz)")
            }
            if let problem = preview.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One stacked-frames picture, its caption, and a legend with color swatches for its lines.
/// The picture is 130 points high (the pane scrolls when that is too much) and as wide as it
/// is given; the caption and legend wrap rather than being cut off. The frame at `position`
/// (the Frame slider's place) is highlighted.
struct ConvertOverview: View {
    let frames: [[Float]]
    let caption: String
    /// The interpolation to draw between the stored frames; nil when nothing says.
    let interpolation: Interpolation?
    /// The words after "Frames in the file" when `interpolation` is nil.
    let unstatedLegend: String
    /// Why the table plays with `interpolation` when its file does not say (the 3rd Wave's
    /// default); nil when the file says, or nothing is known.
    var interpolationNote: String? = nil
    /// The table's color: the source's (`WavetableStackCanvas.sourceColor`) or the result's
    /// (`resultColor`), the same in the cycle picture beside them.
    let tint: Color
    /// The Frame slider's place, 0…1.
    let position: Double

    /// Room for four lines of legend under every picture, so the three legends end at one
    /// height whatever they say, and the Frame slider under them keeps its place as the words
    /// change ("frame 9 of 64" to "between frames 15 and 16 (crossfade)" wraps differently).
    static let legendHeight: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WavetableStackCanvas(frames: frames, interpolation: interpolation, tint: tint, highlight: position)
                .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130)
                // The caption and legend say what the picture shows; VoiceOver gets them below.
                .accessibilityHidden(true)
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            ConvertOverviewLegend(interpolation: interpolation, unstated: unstatedLegend, note: interpolationNote, tint: tint)
                .frame(minHeight: ConvertOverview.legendHeight, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // One element: the caption ("Input · 64 × 2,048"), then the legend's lines.
        .accessibilityElement(children: .combine)
    }
}

/// The result picture's place while the conversion runs on the background queue: a spinner
/// where the picture will be, with the destination's name as the caption.
struct ConvertPreviewPending: View {
    let caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130)
            Text("\(caption) · converting…").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// The cycle at the Frame slider's place, drawn large: the source's in the stored-frame
/// color and the result's over it in the accent color, both to one scale (full scale, or the
/// louder of the two when a table goes beyond it, so a table that was turned down shows
/// smaller). Under it, which frames each comes from ("Frame 12 of 64"; "Between frames 12 and
/// 13 (crossfade)"), from `WavetableSketch.cycle(at:in:interpolation:)`. (The pink line in the
/// stacks marks the slider's place; here the two tables need two colors of their own.)
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
            .frame(minHeight: ConvertOverview.legendHeight, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // One element: the caption, then which frame of each table is drawn.
        .accessibilityElement(children: .combine)
    }
}

/// Two cycles over each other, to one scale: the source's and, when there is one, the result's,
/// in the colors of their stacks (`WavetableStackCanvas.sourceColor`, `resultColor`).
struct SweepCycleCanvas: View {
    let source: [Float]
    let result: [Float]?

    var body: some View {
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            let peak = max(1, (source + (result ?? [])).reduce(Float(0)) { max($0, abs($1)) })
            let amplitude = (size.height / 2 - 2) / CGFloat(peak)
            let base = size.height / 2
            // The center line, for the scale.
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
    /// Why the table plays this way when its file does not say (see `ConvertOverview`).
    var note: String? = nil
    let tint: Color

    private var storedWords: String {
        guard let mode = interpolation else { return "Frames in the file · " + unstated }
        guard mode == Interpolation.none else { return "Frames in the file" }
        return "Frames in the file (the table steps between them" + (note.map { "; " + $0 } ?? "") + ")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ConvertSwatch(color: tint, text: storedWords)
            if interpolation == .crossfade {
                ConvertSwatch(color: WavetableStackCanvas.crossfadeColor(tint), text: "Crossfades" + (note.map { " (" + $0 + ")" } ?? ""))
            } else if interpolation == .spectral {
                ConvertSwatch(color: WavetableStackCanvas.spectralColor, text: "Spectral blends (approx.)" + (note.map { " (" + $0 + ")" } ?? ""))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// A short line of color and a few words, which wrap in a narrow pane.
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
/// interpolation, thinner lines in a second color fill each gap (up to five per gap), the
/// stored frames thin to 24 and the stack is drawn closer together, so the fill reads as a
/// surface; the picture stays within about 150 lines. With `highlight` set (0 front to 1
/// back, the Frame slider's place), the cycle at that depth is drawn over the stack in
/// the highlight color: a stored frame, or the in-between the interpolation gives there.
///
/// Two canvases, one over the other: the stack (`StackLinesCanvas`, which SwiftUI redraws only
/// when the frames, interpolation, or color change) and the highlight, which alone follows the
/// slider, so dragging it costs one line, not the 150 behind it.
struct WavetableStackCanvas: View {
    let frames: [[Float]]
    let interpolation: Interpolation?
    /// The color of the stored frames: the table's own, so the source and the result keep
    /// their colors across the pictures (`sourceColor`, `resultColor`).
    var tint: Color = WavetableStackCanvas.sourceColor
    var highlight: Double? = nil

    /// The source's color, in its stack and in the cycle picture.
    static let sourceColor = Color.primary
    /// The result's color, in its stack and in the cycle picture.
    static let resultColor = Color.accentColor
    /// The color of crossfade in-betweens: the table's own, fainter.
    static func crossfadeColor(_ tint: Color) -> Color { tint.opacity(0.55) }
    /// The color of spectral in-betweens, whichever table they belong to.
    static let spectralColor = Color.purple
    /// The color of the highlighted cycle: one the page uses for nothing else (orange is for
    /// warnings, purple for spectral blends, the accent color for the result).
    static let highlightColor = Color.pink

    var body: some View {
        ZStack {
            StackLinesCanvas(frames: frames, interpolation: interpolation, tint: tint)
                .equatable()
            if let highlight {
                StackHighlightCanvas(frames: frames, interpolation: interpolation, highlight: highlight)
            }
        }
    }

    /// Where the stack sits in a picture of `size`: how far back it recedes and the room each
    /// frame has. Closer together with in-betweens, so the lines merge into a surface.
    struct Geometry {
        let depthX: CGFloat
        let depthY: CGFloat
        let waveWidth: CGFloat
        let amplitude: CGFloat
        let size: CGSize

        init(size: CGSize, showsBetweens: Bool) {
            self.size = size
            depthX = size.width * (showsBetweens ? 0.22 : 0.3)
            depthY = size.height * (showsBetweens ? 0.36 : 0.5)
            waveWidth = size.width - depthX
            amplitude = (size.height - depthY) / 2 - 1
        }

        /// A frame's polyline at depth `t` (0 front, 1 back).
        func path(_ values: [Float], at t: CGFloat) -> Path {
            WavetableStackCanvas.path(values, x0: depthX * t, base: size.height - amplitude - 1 - depthY * t,
                                      width: waveWidth, amplitude: amplitude)
        }
    }

    /// Whether in-betweens are drawn for an interpolation.
    static func showsBetweens(_ interpolation: Interpolation?) -> Bool {
        interpolation == .crossfade || interpolation == .spectral
    }

    /// How many values a frame is reduced to for a picture of `width`: about one per two points.
    static func columns(for width: CGFloat) -> Int { max(8, Int(width * 0.7 / 2)) }

    /// The stored frames reduced for a picture of `width` (the budget leaves room for the
    /// in-betweens when they are drawn).
    static func reducedFrames(_ frames: [[Float]], interpolation: Interpolation?, width: CGFloat) -> [[Float]] {
        let budget = WavetableSketch.lineBudget(storedFrames: frames.count, showsBetweens: showsBetweens(interpolation))
        return WavetableSketch.reduce(frames, maxFrames: budget.stored, columns: columns(for: width))
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

/// The stack itself: the stored frames and the in-betweens, back to front. Equatable, so that
/// SwiftUI leaves it as drawn while only the highlight over it moves.
struct StackLinesCanvas: View, Equatable {
    let frames: [[Float]]
    let interpolation: Interpolation?
    let tint: Color

    /// A line to draw: its depth in frames from the front, its values, and whether it is an
    /// in-between.
    private struct Line {
        var position: Double
        var values: [Float]
        var between: Bool
    }

    var body: some View {
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            let showsBetweens = WavetableStackCanvas.showsBetweens(interpolation)
            let lines = StackLinesCanvas.lines(frames, interpolation: interpolation, showsBetweens: showsBetweens, width: size.width)
            guard let last = lines.first?.position, last > 0 || lines.count == 1 else { return }
            let geometry = WavetableStackCanvas.Geometry(size: size, showsBetweens: showsBetweens)
            let betweenColor = interpolation == .spectral ? WavetableStackCanvas.spectralColor : WavetableStackCanvas.crossfadeColor(tint)
            for line in lines {
                let t: CGFloat = last > 0 ? CGFloat(line.position / last) : 0
                let path = geometry.path(line.values, at: t)
                let fade = 1 - 0.6 * Double(t)
                if line.between {
                    context.stroke(path, with: .color(betweenColor.opacity(0.6 * fade)), lineWidth: 0.6)
                } else {
                    context.stroke(path, with: .color(tint.opacity(fade)), lineWidth: showsBetweens ? 1 : 1.2)
                }
            }
        }
    }

    /// The lines back to front: the stored frames (reduced) and the in-betweens, sorted by
    /// depth so the front ones are drawn last.
    private static func lines(_ frames: [[Float]], interpolation: Interpolation?, showsBetweens: Bool, width: CGFloat) -> [Line] {
        let budget = WavetableSketch.lineBudget(storedFrames: frames.count, showsBetweens: showsBetweens)
        let reduced = WavetableStackCanvas.reducedFrames(frames, interpolation: interpolation, width: width)
        var out: [Line] = reduced.enumerated().map { (pair: (offset: Int, element: [Float])) -> Line in
            Line(position: Double(pair.offset), values: pair.element, between: false)
        }
        for b in WavetableSketch.inBetweens(reduced, interpolation: interpolation, perGap: budget.perGap) {
            out.append(Line(position: b.position, values: b.values, between: true))
        }
        return out.sorted { (a: Line, b: Line) -> Bool in a.position > b.position }
    }
}

/// The cycle at the slider, over the stack, at its depth. Taken from the drawn (reduced)
/// frames, so it sits exactly on them: a stored frame, or the in-between the interpolation
/// gives there (`WavetableSketch.cycle`).
struct StackHighlightCanvas: View {
    let frames: [[Float]]
    let interpolation: Interpolation?
    let highlight: Double

    var body: some View {
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            let stored = WavetableStackCanvas.reducedFrames(frames, interpolation: interpolation, width: size.width)
            guard let point = WavetableSketch.cycle(at: highlight, in: stored, interpolation: interpolation, columns: stored.first?.count ?? 1) else { return }
            let geometry = WavetableStackCanvas.Geometry(size: size, showsBetweens: WavetableStackCanvas.showsBetweens(interpolation))
            context.stroke(geometry.path(point.values, at: CGFloat(highlight)), with: .color(WavetableStackCanvas.highlightColor), lineWidth: 1.6)
        }
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
                if let preview = state.convertPreview(item) {
                    if let file = preview.file {
                        ConvertNoteList(file: file, output: plan.expected(for: item), unchanged: plan.unchangedWords(for: item))
                    } else {
                        Label("The table can’t be converted; the report after converting says why.", systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("Converting…").foregroundStyle(.secondary)
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
    /// What to say when the writer has no notes (`ConvertPlan.unchangedWords(for:)`).
    var unchanged: String = "Only the file format changes."

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
                Text(unchanged).font(.caption).foregroundStyle(.secondary)
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
