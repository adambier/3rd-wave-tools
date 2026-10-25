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

/// The right-hand pane of the Convert page: the destinations in two groups, a line on what they
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
                    Text("Convert to").font(.headline)
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
                Text("Send to Pack also adds the .wt files to the Pack page.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
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
        Button(action: choose) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.shortTitle)
                    Text(preset.specLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if chosen {
                        Text(preset.distinction)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                ConvertEvidenceIcon(preset: preset)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A book when the preset rests on documentation alone, a green seal when it has been tested;
/// the sources and the tested status on hover.
struct ConvertEvidenceIcon: View {
    let preset: OutputPreset
    var body: some View {
        let tested = preset.testedIn
        if tested.isEmpty {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
                .help("Not yet tested in its synth. Follows: " + preset.basis)
        } else {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .help("Tested in " + ConvertPlan.listPhrase(tested) + ". Follows: " + preset.basis)
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
                if preset.recordsInterpolation { ConvertMorphOption(state: state) }
                if preset == .tonverk { ConvertTonverkSizeOption(state: state) }
                if preset == .thirdWaveP { ConvertPPGOption(state: state) }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Keep original frames or blend new ones, when the destination needs a different count.
struct ConvertFrameCountOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        let affected = state.convertPlan.frameCountChangeCount
        VStack(alignment: .leading, spacing: 4) {
            Text("If the destination needs more or fewer frames")
            Picker("", selection: $state.convertPlan.options.frameCountPolicy) {
                Text("Keep original frames").tag(FrameCountPolicy.pickEvenly)
                Text("Blend new frames").tag(FrameCountPolicy.interpolate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Keep original frames: uses evenly spaced frames, including the first and last; adds no new waves (adding frames repeats some).\nBlend new frames: crossfades neighbouring frames to make the new ones.")
            Text(affected == 0 ? "Every table already fits." : "Affects \(affected) table\(affected == 1 ? "" : "s").")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// What the file records about moving between frames, for destinations whose files can.
struct ConvertMorphOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        let tonverk = state.convertPlan.preset == .tonverk
        VStack(alignment: .leading, spacing: 4) {
            Text("Morph saved in file")
            Picker("", selection: $state.convertPlan.options.interpolation) {
                Text("Same as source").tag(Optional<Interpolation>.none)
                Text("Steps").tag(Optional<Interpolation>.some(Interpolation.none))
                Text("Crossfade").tag(Optional<Interpolation>.some(Interpolation.crossfade))
                Text("Spectral").tag(Optional<Interpolation>.some(Interpolation.spectral))
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            .help(tonverk
                  ? "Tonverk reads stepping from the file name (a trailing r means steps); it has no spectral morph, so Spectral is written as smooth. Other synths set this on the oscillator."
                  : "Serum and Vital read it from the WAV; Tonverk reads stepping from the file name. Other synths set this on the oscillator.")
            Text("Same as source saves crossfade when the source doesn't say.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Tonverk's frame size, written into the file name.
struct ConvertTonverkSizeOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tonverk frame size")
            Picker("", selection: $state.convertPlan.options.tonverkFrameSize) {
                Text("Same as source (2,048 if Tonverk can't use it)").tag(Optional<Int>.none)
                ForEach([64, 128, 256, 512, 1024, 2048, 4096], id: \.self) { (n: Int) in
                    Text(ConvertPlan.formatCount(n)).tag(Optional<Int>.some(n))
                }
            }
            .labelsHidden()
            Text("Saved in the file name (e.g., _wt1024).")
                .font(.caption).foregroundStyle(.secondary)
        }
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
