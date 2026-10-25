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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Convert to").font(.headline)
                        Text(ConvertDestinationPane.scope(plan.selectedItems.count))
                            .font(.caption).foregroundStyle(.secondary)
                        if let capacity = plan.thirdWaveCapacityNote {
                            Label {
                                Text(capacity).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                            }
                            .font(.caption).foregroundStyle(.orange)
                            .padding(.top, 2)
                        }
                    }
                    ForEach(OutputPreset.Group.allCases, id: \.self) { (group: OutputPreset.Group) in
                        ConvertPresetGroup(state: state, group: group)
                    }
                    Text(ConvertPlan.testingFootnote)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ConvertOptionsBox(state: state)
                }
                .padding(12)
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

    /// "For all 75 tables to convert": the destination and its options apply to every table
    /// marked to convert, unlike the preview below the table.
    static func scope(_ marked: Int) -> String {
        switch marked {
        case 0: return "No tables are marked to convert yet."
        case 1: return "For the 1 table to convert."
        default: return "For all \(marked) tables to convert."
        }
    }
}

/// A group heading and its destinations.
struct ConvertPresetGroup: View {
    @ObservedObject var state: AppState
    let group: OutputPreset.Group

    var body: some View {
        let st = state
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            ForEach(group.presets, id: \.self) { (p: OutputPreset) in
                ConvertPresetRow(preset: p, chosen: p == st.convertPlan.preset) { st.convertPlan.preset = p }
            }
        }
    }
}

/// One destination: a radio, its short title and size, and whether it has been tested; the
/// chosen one also says why it is a destination of its own.
struct ConvertPresetRow: View {
    let preset: OutputPreset
    let chosen: Bool
    let choose: () -> Void

    var body: some View {
        // The row chooses the destination; the sources icon beside it is its own button, so
        // clicking it opens the sources rather than choosing the row. A tap gesture rather than
        // a Button: a plain Button's label did not redraw its radio when the choice changed.
        HStack(alignment: .top, spacing: 4) {
            ConvertPresetRowLabel(preset: preset, chosen: chosen)
                .onTapGesture { choose() }
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : [.isButton])
            ConvertSourcesButton(preset: preset)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.12) : Color.clear))
    }
}

/// The radio, title, spec line, and (when chosen) why this destination is separate, plus any caveat.
struct ConvertPresetRowLabel: View {
    let preset: OutputPreset
    let chosen: Bool

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
                if let caveat = preset.caveat {
                    // What the sources leave open, in the open rather than on hover.
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

/// A book when the destination rests on its sources alone, a green seal when it has been tested.
/// Clicking it shows the sources (publisher and document) and the tested status.
struct ConvertSourcesButton: View {
    let preset: OutputPreset
    @State private var showing = false

    private var tested: [String] { preset.testedIn }
    private var status: String {
        tested.isEmpty ? "Not yet tested in its synth." : "Tested in " + ConvertPlan.listPhrase(tested) + "."
    }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: tested.isEmpty ? "book.closed" : "checkmark.seal.fill")
                .foregroundStyle(tested.isEmpty ? Color.secondary : Color.green)
        }
        .buttonStyle(.borderless)
        .help("Sources for this destination")
        .popover(isPresented: $showing, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 6) {
                Text(preset.shortTitle).font(.headline)
                Text(status)
                Text("Sources").font(.subheadline).bold().padding(.top, 4)
                Text(preset.basis + ".")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
        }
    }
}

/// The options that apply to the chosen destination, always open.
struct ConvertOptionsBox: View {
    @ObservedObject var state: AppState

    var body: some View {
        let preset = state.convertPlan.preset
        GroupBox("Options") {
            VStack(alignment: .leading, spacing: 12) {
                ConvertFrameCountOption(state: state)
                if preset.recordsInterpolation { ConvertInterpolationOption(state: state) }
                if preset == .tonverk { ConvertTonverkSizeOption(state: state) }
                if preset == .thirdWaveP { ConvertPPGOption(state: state) }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Keep original frames or crossfade new ones, when the destination needs a different count.
struct ConvertFrameCountOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("If the destination needs more or fewer frames")
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

/// The interpolation the file records, for destinations whose files can.
struct ConvertInterpolationOption: View {
    @ObservedObject var state: AppState

    private var tonverk: Bool { state.convertPlan.preset == .tonverk }

    private var tip: String {
        tonverk ? "Tonverk reads it from the file name: a trailing r means stepped, otherwise smooth. Other synths set interpolation on the oscillator."
                : "Serum and Vital read it from the WAV; Tonverk reads it from the file name. Other synths set interpolation on the oscillator."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Interpolation saved in file")
            if tonverk {
                // Tonverk's name says stepped or smooth, nothing else: a spectral choice shows
                // as Smooth, which is what the writer records for it.
                Picker("", selection: tonverkSelection) {
                    Text("Same as Source").tag(Optional<Interpolation>.none)
                    Text("None (Stepped)").tag(Optional<Interpolation>.some(Interpolation.none))
                    Text("Smooth").tag(Optional<Interpolation>.some(Interpolation.crossfade))
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .help(tip)
            } else {
                Picker("", selection: $state.convertPlan.options.interpolation) {
                    Text("Same as Source").tag(Optional<Interpolation>.none)
                    Text("None (Stepped)").tag(Optional<Interpolation>.some(Interpolation.none))
                    Text("Crossfade").tag(Optional<Interpolation>.some(Interpolation.crossfade))
                    Text("Spectral").tag(Optional<Interpolation>.some(Interpolation.spectral))
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .help(tip)
            }
            Text(tonverk ? "Same as Source writes smooth when the source doesn't say. None (Stepped) adds r to the file name."
                         : "Same as Source saves crossfade when the source doesn't say.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The Tonverk menu's selection: a spectral choice reads as Smooth (the writer records it
    /// so), and choosing Smooth stores crossfade.
    private var tonverkSelection: Binding<Interpolation?> {
        Binding(
            get: { state.convertPlan.options.interpolation == .spectral ? Interpolation.crossfade : state.convertPlan.options.interpolation },
            set: { (value: Interpolation?) in state.convertPlan.options.interpolation = value }
        )
    }
}

/// Tonverk's frame size, written into the file name.
struct ConvertTonverkSizeOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tonverk frame size")
            Picker("", selection: $state.convertPlan.options.tonverkFrameSize) {
                Text("Same as Source").tag(Optional<Int>.none)
                ForEach([64, 128, 256, 512, 1024, 2048, 4096], id: \.self) { (n: Int) in
                    Text(ConvertPlan.formatCount(n)).tag(Optional<Int>.some(n))
                }
            }
            .labelsHidden()
            .help("Same as Source keeps the source's frame size when Tonverk takes it (64 to 4,096, powers of two) and writes 2,048 otherwise.")
            Text(exampleLine)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help("Tonverk reads the frame size from the _wt tag at the end of the file name, and plays the table stepped when the name ends in r.")
        }
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
