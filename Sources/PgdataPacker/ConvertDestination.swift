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

/// The Wavetables page's right pane, narrow: the destinations in two groups, one line each, a
/// line on what they rest on, and the options that apply to the one chosen. Laid out to fit
/// without scrolling at the default window size; it scrolls in a shorter window.
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
                            Text(ConvertDestinationPane.scope(plan.includedItems.count, of: plan.items.count))
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
                    ConvertOptionsBox(state: state)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if plan.preset.isThirdWave {
                Divider()
                Text("To load .wt files: copy the WAVES folder onto the 3rd Wave’s USB drive and use Global → “Bulk wavetable import”, or add the files to the 3rd Wave Terminal app’s library and sync.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    /// Under "Convert to": what the destination and its options apply to ("For all 75 tables."),
    /// unlike the preview above, which is one table's. Convert All's set is named when factory
    /// tables are left out of it.
    static func scope(_ included: Int, of total: Int) -> String {
        if total == 0 { return "No tables yet." }
        if included == total { return total == 1 ? "For the one table." : (total == 2 ? "For both tables." : "For all \(total) tables.") }
        return "For every table; Convert All takes \(included) of \(total) (factory tables left out)."
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
        // The row is a button that chooses the destination, so the keyboard reaches it and
        // VoiceOver reads it as one element, like a radio button; the sources icon beside it is
        // its own button, so clicking it opens the sources rather than choosing the row. (The
        // row's `.id` in `ConvertPresetGroup` changes with the choice, which is what makes the
        // radio redraw; a plain Button's label alone did not.)
        HStack(alignment: .top, spacing: 4) {
            Button { choose() } label: {
                ConvertPresetRowLabel(preset: preset, chosen: chosen, caveat: caveat)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(chosen ? AccessibilityTraits.isSelected : [])
            ConvertSourcesButton(preset: preset)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.12) : Color.clear))
    }
}

/// Splits a paragraph into its sentences, at a period, exclamation mark, or question mark
/// followed by a space and a capital letter or an opening quotation mark; a period inside a
/// number or a parenthesis stays.
func sentencesOfParagraph(_ text: String) -> [String] {
    var out: [String] = []
    var current = ""
    let chars = Array(text)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        current.append(c)
        if ".!?".contains(c), i + 2 < chars.count, chars[i + 1] == " ",
           chars[i + 2].isUppercase || chars[i + 2] == "\u{201C}" || chars[i + 2] == "(" {
            out.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
            i += 1   // the space
        }
        i += 1
    }
    let last = current.trimmingCharacters(in: .whitespaces)
    if !last.isEmpty { out.append(last) }
    return out
}

/// The radio, title, spec line, and (when chosen) why this destination is separate, then its
/// cautions in orange: what its sources leave open for these tables, if anything, and that
/// converting to it has not been tested, unless it has (`OutputPreset.testedIn`).
struct ConvertPresetRowLabel: View {
    let preset: OutputPreset
    let chosen: Bool
    let caveat: String?

    /// The distinction's sentences, one paragraph each (see `sentencesOfParagraph`).
    static func sentences(of text: String) -> [String] { sentencesOfParagraph(text) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Two views rather than one image whose name changes, so the radio always redraws.
            if chosen {
                Image(systemName: "largecircle.fill.circle").foregroundStyle(Color.accentColor).padding(.top, 1)
            } else {
                Image(systemName: "circle").foregroundStyle(Color.secondary).padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                // Title and size on one line, so the nine destinations fit the pane's height.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(preset.shortTitle)
                    Text(preset.specLine).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                if chosen {
                    // One sentence per paragraph, a little apart, rather than a block of small
                    // type (Adam, 2026-10-26).
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(ConvertPresetRowLabel.sentences(of: preset.distinction).enumerated()), id: \.offset) { (pair: (offset: Int, element: String)) in
                            Text(pair.element).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption)
                    .padding(.top, 2)
                    if let caveat { ConvertCaution(text: caveat) }
                    // While the page carries its under-development notice, the row does not say
                    // "untested" a second time; the Sources popover still does.
                    if preset.testedIn.isEmpty, !ConvertPlan.conversionUnderDevelopment { ConvertCaution(text: ConvertPlan.testingStatus(preset)) }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// One caution under a destination: a triangle and a sentence or two, in orange.
struct ConvertCaution: View {
    let text: String
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.top, 2)
    }
}

/// Heads the column of book icons: "Sources" with an info icon, so it reads as something to
/// click; it opens a note on what the icons show and why to look.
struct ConvertSourcesHeader: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label("Sources", systemImage: "info.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("What each destination rests on, and whether converting to it has been tested")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sources").font(.headline)
                Text("Each destination follows the documents or source code published for that synth. Click a destination’s book to see those sources, what the sources leave open, and whether a converted file has been tested in the synth.")
                    .fixedSize(horizontal: false, vertical: true)
                Label("A green seal marks a destination that has been tested.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
            .lineLimit(nil)   // whatever the anchor's environment says
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
        .accessibilityLabel("Sources for \(preset.shortTitle)")
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
                    Text("What the sources leave open").font(.subheadline).bold().padding(.top, 4)
                    Text(open)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
            .lineLimit(nil)   // whatever the anchor's environment says
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
        if frameCount || preset.recordsInterpolation || preset == .tonverk || preset.isThirdWave {
            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 12) {
                    if frameCount { ConvertFrameCountOption(state: state) }
                    if preset.recordsInterpolation { ConvertInterpolationOption(state: state) }
                    if preset == .tonverk { ConvertTonverkSizeOption(state: state) }
                    if preset == .thirdWaveP { ConvertPPGOption(state: state) }
                    if preset.isThirdWave { ConvertPackOption(state: state) }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 10)   // set apart from the destination list
        }
    }
}

/// A picker item's two parts (`ConvertPlan.ChoiceLabel`): the value, then what the tables
/// already have after a dash and in italics ("Crossfade — *existing*").
private func choiceText(_ label: ConvertPlan.ChoiceLabel) -> Text {
    guard let existing = label.existing else { return Text(label.value) }
    return Text(label.value) + Text(" — " + existing).italic()
}

/// Original frames only (picked evenly or repeated) or crossfade new ones; shown when some
/// table to convert gains or loses frames for the destination.
struct ConvertFrameCountOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The destination needs more or fewer frames")
            // The pickers' titles name them for VoiceOver; the text above each shows the words.
            Picker("If the destination needs more or fewer frames", selection: $state.convertPlan.options.frameCountPolicy) {
                Text("Original Frames Only").tag(FrameCountPolicy.pickEvenly)
                Text("Crossfade New Frames").tag(FrameCountPolicy.interpolate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Original frames only: no new waveforms are made. Fewer frames keeps evenly spaced originals, the first and last among them (256 → 64 keeps about every 4th); more frames repeats each original in order (16 → 64 repeats each about 4 times).\nCrossfade new frames: makes each new frame by crossfading its two neighbors. This happens once, when converting; it is separate from the interpolation saved in the file, which is how the synth moves between frames as it plays.")
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
        tonverk ? "Tonverk reads the interpolation from the file name: a trailing \u{201C}r\u{201D} means stepped, otherwise crossfade (Tonverk’s manual says \u{201C}smooth\u{201D}, taken here to mean a crossfade)."
                : "Serum and Vital read the interpolation from the WAV. Other synths set the interpolation method on the oscillator."
    }

    /// The values the destination can record. Tonverk's name says stepped or smooth, nothing
    /// else (a spectral table is marked smooth, which is what the writer records for it).
    private var choices: [Interpolation] {
        tonverk ? [Interpolation.none, .crossfade] : [Interpolation.none, .crossfade, .spectral]
    }

    /// The menu's words for a value: its `displayName` (Tonverk's manual says "smooth" for a
    /// crossfade; the page keeps one word for one thing).
    private func label(_ value: Interpolation) -> String { value.displayName }

    /// What the choices mean, and what "existing" means when the menu says it. One sentence
    /// each, nothing the menu already says.
    private var caption: String {
        let plan = state.convertPlan
        var lines: [String] = []
        if plan.sharedExistingInterpolation != nil || plan.eachTablesOwnInterpolationLabel != nil {
            var sentence = "\u{201C}Existing\u{201D} is what a table’s file states"
            if plan.unstatedInterpolationCount > 0 {
                sentence += "; a file that states nothing is saved as crossfade"
            }
            lines.append(sentence + ".")
        }
        if tonverk {
            lines.append("Crossfade is an interpolation method: each frame blends into the next. None is no interpolation: Tonverk steps from frame to frame, and the file name gets an \u{201C}r\u{201D}.")
        } else {
            lines.append("Crossfade and spectral are interpolation methods: crossfade blends each frame into the next; spectral blends the frames’ harmonics (Serum’s and Vital’s spectral morph). None is no interpolation: the synth steps from frame to frame.")
        }
        return lines.joined(separator: " ")
    }

    var body: some View {
        let plan = state.convertPlan
        let shared = plan.sharedExistingInterpolation
        // The item that stands for no override (nil): the value every file states, or, when no
        // file states any, the writer's default; neither is marked unless it is "existing".
        let unmarkedDefault = shared ?? plan.defaultInterpolationItem
        VStack(alignment: .leading, spacing: 4) {
            Text(tonverk ? "Interpolation marked in the file name" : "Interpolation saved in the file")
            Picker(tonverk ? "Interpolation marked in the file name" : "Interpolation saved in the file", selection: selection) {
                if let own = plan.eachTablesOwnInterpolationLabel {
                    choiceText(own).tag(Optional<Interpolation>.none)
                }
                ForEach(choices, id: \.self) { (value: Interpolation) in
                    choiceText(ConvertPlan.ChoiceLabel(value: label(value), existing: value == shared ? "existing" : nil))
                        .tag(value == unmarkedDefault ? Optional<Interpolation>.none : Optional<Interpolation>.some(value))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)   // under its label, not centered in the room
            // The "Each table's own — existing: …" item can be longer than the pop-up; its tip
            // carries the full text.
            .help((plan.eachTablesOwnInterpolationLabel.map { $0.text + "\n" } ?? "") + tip)
            Text(caption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The menu's selection: nil (no override) for the item that stands for it (the existing
    /// value, or the default when no file states one), which the option also maps to when it
    /// equals that value; for Tonverk, a spectral choice reads as smooth and choosing smooth
    /// stores crossfade.
    private var selection: Binding<Interpolation?> {
        Binding(
            get: {
                let plan = state.convertPlan
                var value = plan.options.interpolation
                if tonverk, value == .spectral { value = .crossfade }
                let unmarkedDefault = plan.sharedExistingInterpolation ?? plan.defaultInterpolationItem
                return value == unmarkedDefault ? nil : value
            },
            set: { (value: Interpolation?) in
                let plan = state.convertPlan
                let unmarkedDefault = plan.sharedExistingInterpolation ?? plan.defaultInterpolationItem
                state.convertPlan.options.interpolation = value == unmarkedDefault ? nil : value
            }
        )
    }
}

/// Tonverk's frame size, written into the file name. The menu lists the sizes Tonverk takes and
/// marks the one every table to convert has ("2,048 — existing"), which stands for no override;
/// when they differ, or a table has a size Tonverk doesn't take, a first item keeps each table's
/// own ("Each table's own — existing: 1,024 and 2,048"). From `ConvertPlan.existingFrameSizes()`.
/// The file name each table gets is shown in the preview, not here: it is one table's.
struct ConvertTonverkSizeOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        let plan = state.convertPlan
        let shared = plan.sharedTonverkFrameSize
        VStack(alignment: .leading, spacing: 4) {
            Text("Tonverk frame size")
            Picker("Tonverk frame size", selection: selection) {
                if let own = plan.eachTablesOwnFrameSizeLabel {
                    choiceText(own).tag(Optional<Int>.none)
                }
                ForEach(WavetableWriter.tonverkFrameSizes, id: \.self) { (n: Int) in
                    choiceText(ConvertPlan.ChoiceLabel(value: ConvertPlan.formatCount(n), existing: n == shared ? "existing" : nil))
                        .tag(n == shared ? Optional<Int>.none : Optional<Int>.some(n))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
            .help((plan.eachTablesOwnFrameSizeLabel.map { $0.text + "\n" } ?? "") + "\u{201C}Existing\u{201D} is the frame size the tables already have; Tonverk takes 64 to 4,096 (powers of two), and a table of another size is written at 2,048. Any other choice resamples every table to that size. The size goes into the file name as a _wt tag (the preview shows each table’s); a trailing \u{201C}r\u{201D} marks a stepped table.")
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
}

/// For a 3rd Wave destination: whether the .wt files written are then added to the Pack page
/// (`AppState.convertAddsToPack`), which both Convert buttons honor.
struct ConvertPackOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        Toggle("Also add the .wt files to the Pack page", isOn: $state.convertAddsToPack)
            .toggleStyle(.checkbox)
            .help("After converting, the .wt files are added to the Pack page’s “Added Wavetables and Samples”, ready to embed in a .pgdata, and that page is shown. The files stay where they were written.")
    }
}

/// The PPG's four standard waveforms at 60–63 of a P table.
struct ConvertPPGOption: View {
    @ObservedObject var state: AppState

    var body: some View {
        Toggle("Add the PPG’s standard waveforms at 60–63", isOn: $state.convertPlan.options.appendPPGStandardWaves)
            .toggleStyle(.checkbox)
            .help("Triangle, narrow pulse, square, and sawtooth, as in the 3rd Wave’s PPG-derived P tables. Your table is fitted into frames 0–59, the part the 3rd Wave sweeps when \u{201C}use upper wavetable\u{201D} is off.")
    }
}
