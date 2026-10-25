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

/// The right-hand pane of the Wavetables page: the destinations in two groups, a line on what they
/// rest on, and the options that apply to the one chosen.
struct ConvertDestinationPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let plan = state.convertPlan
        VStack(spacing: 0) {
            // Scrolls rather than setting the pane's height, so a short window never pushes the
            // page's top out of view.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Convert to").font(.headline)
                            Text(ConvertDestinationPane.scope(plan.selectedItems.count))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        // Heads the column of book icons; aligned with them (the rows have the
                        // same 6-point inset).
                        ConvertSourcesHeader().padding(.trailing, 6)
                    }
                    // The chosen destination and its note go down as values, so the groups and
                    // rows are laid out again whenever they change. (With the rows reading the
                    // choice from the state object themselves, the radio and highlight stayed on
                    // the destination chosen at launch while the rest of the pane followed the
                    // new one.)
                    ForEach(OutputPreset.Group.allCases, id: \.self) { (group: OutputPreset.Group) in
                        ConvertPresetGroup(group: group, chosen: plan.preset, caveat: plan.caveat(for: plan.preset)) {
                            state.convertPlan.preset = $0
                        }
                    }
                    Text(ConvertPlan.testingFootnote)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ConvertOptionsBox(state: state)
                }
                .padding(12)
                // Room for the scroll bar, which lies over the content when it is shown.
                .padding(.trailing, ConvertDestinationPane.scrollerInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .visibleScrollers()
            if plan.preset.isThirdWave {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("To load .wt files: copy the WAVES folder onto the 3rd Wave's USB drive, then Global → Bulk wavetable import. A 3rd Wave has 8 slots for your own U tables (U56–U63) and 12 for P tables (P36–P47).")
                    Text("Send to Pack also adds the .wt files to the Pack page.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    /// The width a classic scroll bar covers at the trailing edge of a SwiftUI ScrollView's
    /// content (`visibleScrollers()` makes the bars classic; SwiftUI lays the content out at the
    /// full width regardless, so the bar lay over the right edge of the text).
    static let scrollerInset: CGFloat = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    /// "For all 75 tables to convert": the destination and its options apply to every table
    /// marked to convert, unlike the preview below the table.
    static func scope(_ marked: Int) -> String {
        switch marked {
        case 0: return "No tables are marked to convert yet."
        case 1: return "For the one table to convert."
        case 2: return "For both tables to convert."
        default: return "For all \(marked) tables to convert."
        }
    }
}

/// A group heading and its destinations. A function of its inputs: the destination chosen
/// comes in as a value and a choice goes out through `choose`.
struct ConvertPresetGroup: View {
    let group: OutputPreset.Group
    let chosen: OutputPreset
    /// The orange note for the chosen destination, when the tables bring one about
    /// (`ConvertPlan.caveat(for:)`); shown on that row only.
    let caveat: String?
    let choose: (OutputPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            ForEach(group.presets, id: \.self) { (p: OutputPreset) in
                ConvertPresetRow(preset: p, chosen: p == chosen, caveat: p == chosen ? caveat : nil) { choose(p) }
                    // A new identity when the row's state changes, so the radio, the highlight,
                    // and the lines that only the chosen row shows are all drawn afresh.
                    .id("\(p.rawValue)-\(p == chosen)")
            }
        }
    }
}

/// One destination: a radio, its short title and size, and the icon that opens its sources; the
/// chosen one also says why it is a destination of its own, and warns when the tables to
/// convert bring about something its sources leave open.
struct ConvertPresetRow: View {
    let preset: OutputPreset
    let chosen: Bool
    let caveat: String?
    let choose: () -> Void

    var body: some View {
        // The row chooses the destination; the sources icon beside it is its own button, so
        // clicking it opens the sources rather than choosing the row. A tap gesture rather than
        // a Button: a plain Button's label did not redraw its radio when the choice changed.
        HStack(alignment: .top, spacing: 4) {
            ConvertPresetRowLabel(preset: preset, chosen: chosen, caveat: caveat)
                .onTapGesture { choose() }
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : [.isButton])
            ConvertSourcesButton(preset: preset)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.12) : Color.clear))
    }
}

/// The radio, title, spec line, and (when chosen) why this destination is separate and the
/// note, if any, on what its sources leave open for these tables.
struct ConvertPresetRowLabel: View {
    let preset: OutputPreset
    let chosen: Bool
    let caveat: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Two views rather than one image whose name changes, so the radio always redraws.
            if chosen {
                Image(systemName: "largecircle.fill.circle").foregroundStyle(Color.accentColor).padding(.top, 1)
            } else {
                Image(systemName: "circle").foregroundStyle(Color.secondary).padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.shortTitle)
                Text(preset.specLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if chosen {
                    Text(preset.distinction)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if let caveat {
                    Label {
                        Text(caveat).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Heads the column of book icons: "Sources", which opens a note on what the icons show and
/// why to look.
struct ConvertSourcesHeader: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Text("Sources").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("What each destination rests on, and whether converting to it has been tested")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sources").font(.headline)
                Text("Each destination follows the documents or source code published for that synth. Click a destination's book to see them, what they leave open, and whether a converted file has been tested in the synth.")
                    .fixedSize(horizontal: false, vertical: true)
                Label("A green seal marks a destination that has been tested.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
        }
    }
}

/// A book when the destination rests on its sources alone, a green seal when it has been tested.
/// Clicking it shows the sources (publisher and document), what they leave open, and whether
/// converting to the destination has been tested.
struct ConvertSourcesButton: View {
    let preset: OutputPreset
    @State private var showing = false

    private var tested: Bool { !preset.testedIn.isEmpty }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: tested ? "checkmark.seal.fill" : "book.closed")
                .foregroundStyle(tested ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help("Sources for this destination, and whether converting to it has been tested")
        .popover(isPresented: $showing, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 6) {
                Text(preset.shortTitle).font(.headline)
                Text(ConvertPlan.testingStatus(preset))
                Text("Sources").font(.subheadline).bold().padding(.top, 4)
                Text(preset.basis + ".")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let open = preset.caveat {
                    Text("What they leave open").font(.subheadline).bold().padding(.top, 4)
                    Text(open)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
        }
    }
}

/// The options that apply to the chosen destination and these tables, always open; nothing
/// when none applies (the frame-count choice only when some table to convert gains or loses
/// frames for the destination).
struct ConvertOptionsBox: View {
    @ObservedObject var state: AppState

    var body: some View {
        let plan = state.convertPlan
        let preset = plan.preset
        let changes = plan.frameCountChanges
        let frameCount = changes.gain + changes.lose > 0
        if frameCount || preset.recordsInterpolation || preset == .tonverk || preset == .thirdWaveP {
            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 12) {
                    if frameCount { ConvertFrameCountOption(state: state) }
                    if preset.recordsInterpolation { ConvertInterpolationOption(state: state) }
                    if preset == .tonverk { ConvertTonverkSizeOption(state: state) }
                    if preset == .thirdWaveP { ConvertPPGOption(state: state) }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A picker item's two parts (`ConvertPlan.ChoiceLabel`): the value, then what the tables
/// already have after a dash and in italics ("Crossfade — *existing*").
private func choiceText(_ label: ConvertPlan.ChoiceLabel) -> Text {
    guard let existing = label.existing else { return Text(label.value) }
    return Text(label.value) + Text(" — " + existing).italic()
}

/// Keep original frames or crossfade new ones; shown when some table to convert gains or loses
/// frames for the destination.
struct ConvertFrameCountOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The destination needs more or fewer frames")
            Picker("", selection: $state.convertPlan.options.frameCountPolicy) {
                Text("Keep Original Frames").tag(FrameCountPolicy.pickEvenly)
                Text("Crossfade New Frames").tag(FrameCountPolicy.interpolate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Keep original frames: uses evenly spaced frames, including the first and last; adds no new waves (adding frames repeats some).\nCrossfade new frames: makes each new frame by crossfading its two neighbours. This happens once, when converting; it is separate from the interpolation saved in the file, which is how the synth moves between frames as it plays.")
            Text(state.convertPlan.frameCountCaption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The interpolation the file records, for destinations whose files can. The menu lists the
/// values the destination can record and marks the one the tables to convert already have
/// ("Crossfade — existing"), which stands for no override; when they differ, a first item
/// keeps each table's own ("Each table's own — existing: 3 stepped, 2 crossfade"). The counts
/// come from `ConvertPlan.existingInterpolations()`.
struct ConvertInterpolationOption: View {
    @ObservedObject var state: AppState

    private var tonverk: Bool { state.convertPlan.preset == .tonverk }

    private var tip: String {
        tonverk ? "Tonverk reads it from the file name: a trailing r means stepped, otherwise smooth. Other synths set interpolation on the oscillator."
                : "Serum and Vital read it from the WAV; Tonverk reads it from the file name. Other synths set interpolation on the oscillator."
    }

    /// The values the destination can record. Tonverk's name says stepped or smooth, nothing
    /// else (a spectral table is marked smooth, which is what the writer records for it).
    private var choices: [Interpolation] {
        tonverk ? [Interpolation.none, .crossfade] : [Interpolation.none, .crossfade, .spectral]
    }

    /// The menu's words for a value: its `displayName`, except Tonverk's "Smooth" for crossfade
    /// (what its file name says).
    private func label(_ value: Interpolation) -> String {
        value == .crossfade && tonverk ? "Smooth" : value.displayName
    }

    var body: some View {
        let plan = state.convertPlan
        let shared = plan.sharedExistingInterpolation
        VStack(alignment: .leading, spacing: 4) {
            Text("Interpolation saved in the file")
            Picker("", selection: selection) {
                if let own = plan.eachTablesOwnInterpolationLabel {
                    choiceText(own).tag(Optional<Interpolation>.none)
                }
                ForEach(choices, id: \.self) { (value: Interpolation) in
                    // The value the tables already have stands for no override (nil).
                    choiceText(ConvertPlan.ChoiceLabel(value: label(value), existing: value == shared ? "existing" : nil))
                        .tag(value == shared ? Optional<Interpolation>.none : Optional<Interpolation>.some(value))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .help(tip)
            Text(tonverk ? "\u{201C}Existing\u{201D} is the interpolation the tables already have; a file that doesn't say counts as smooth. None (stepped) adds r to the file name."
                         : "\u{201C}Existing\u{201D} is the interpolation the tables already have; a file that doesn't say counts as crossfade.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The menu's selection: nil (no override) for the item marked existing, which the option
    /// also maps to when it equals the value every table has (set before the tables agreed);
    /// for Tonverk, a spectral choice reads as Smooth and choosing Smooth stores crossfade.
    private var selection: Binding<Interpolation?> {
        Binding(
            get: {
                var value = state.convertPlan.options.interpolation
                if tonverk, value == .spectral { value = .crossfade }
                return value == state.convertPlan.sharedExistingInterpolation ? nil : value
            },
            set: { (value: Interpolation?) in
                state.convertPlan.options.interpolation = value == state.convertPlan.sharedExistingInterpolation ? nil : value
            }
        )
    }
}

/// Tonverk's frame size, written into the file name. The menu lists the sizes Tonverk takes and
/// marks the one every table to convert has ("2,048 — existing"), which stands for no override;
/// when they differ, or a table has a size Tonverk doesn't take, a first item keeps each table's
/// own ("Each table's own — existing: 1,024 and 2,048"). From `ConvertPlan.existingFrameSizes()`.
struct ConvertTonverkSizeOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        let plan = state.convertPlan
        let shared = plan.sharedTonverkFrameSize
        VStack(alignment: .leading, spacing: 4) {
            Text("Tonverk frame size")
            Picker("", selection: selection) {
                if let own = plan.eachTablesOwnFrameSizeLabel {
                    choiceText(own).tag(Optional<Int>.none)
                }
                ForEach(WavetableWriter.tonverkFrameSizes, id: \.self) { (n: Int) in
                    choiceText(ConvertPlan.ChoiceLabel(value: ConvertPlan.formatCount(n), existing: n == shared ? "existing" : nil))
                        .tag(n == shared ? Optional<Int>.none : Optional<Int>.some(n))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .help("\u{201C}Existing\u{201D} is the frame size the tables already have; Tonverk takes 64 to 4,096 (powers of two), and a table of another size is written at 2,048. Any other choice resamples every table to that size.")
            Text(exampleLine)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help("Tonverk reads the frame size from the _wt tag at the end of the file name, and plays the table stepped when the name ends in r.")
        }
    }

    /// The menu's selection: nil (no override) for the size marked existing, which the option
    /// also maps to when it equals the size every table has.
    private var selection: Binding<Int?> {
        Binding(
            get: {
                let value = state.convertPlan.options.tonverkFrameSize
                return value == state.convertPlan.sharedTonverkFrameSize ? nil : value
            },
            set: { (value: Int?) in
                state.convertPlan.options.tonverkFrameSize = value == state.convertPlan.sharedTonverkFrameSize ? nil : value
            }
        )
    }

    /// "Saved in the file name: Bass Bridge_wt2048.wav", from the first table to convert with
    /// the current choices (the writer's preview, cached), or a general example.
    private var exampleLine: String {
        let plan = state.convertPlan
        guard let first = plan.selectedItems.first(where: plan.canConvert),
              let file = state.convertPreviews.preview(first, in: plan) else {
            return "Saved in the file name (e.g., Name_wt2048.wav; Name_wt2048r.wav when stepped)."
        }
        return "Saved in the file name: \(file.fileName)"
    }
}

/// The PPG's four standard waves at 60–63 of a P table.
struct ConvertPPGOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        Toggle("Add the PPG's standard waves at 60–63", isOn: $state.convertPlan.options.appendPPGStandardWaves)
            .toggleStyle(.checkbox)
            .help("Triangle, narrow pulse, square, and sawtooth, as in the 3rd Wave's PPG-derived P tables. Your table is fitted into frames 0–59, the part the 3rd Wave sweeps when \u{201C}use upper wavetable\u{201D} is off.")
    }
}
