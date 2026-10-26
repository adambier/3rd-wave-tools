import Foundation
#if canImport(PgdataFormats)
import PgdataFormats   // SwiftPM build; absent in the app’s single-module swiftc build
#endif

/// Writes a wavetable for a destination.
public enum WavetableWriter {
    /// Converts `table` to `preset`'s format: frame size, frame count, sample format, metadata,
    /// and file name.
    ///
    /// What is done is what ``plan(for:preset:options:)`` says for the table. The result's
    /// `notes` say every change made (frame size resampled, frame count changed and how, scaled,
    /// name shortened or adjusted). Frame sizes change by band-limited resampling
    /// (``Resampling/resizeCycle(_:to:)``); frame counts by `options.frameCountPolicy`
    /// (``Resampling/changeFrameCount(_:to:policy:)``). WAVs are written at 48 kHz, except
    /// WaveEdit's 44.1 kHz. The interpolation recorded, where the format can record one, is
    /// `options.interpolation`, else the table's, else crossfade.
    ///
    /// - Throws: ``WavetableError`` of kind ``WavetableError/Kind/cannotConvert`` when the table
    ///   is empty, its frames differ in length, a sample is not a finite number, or
    ///   `options.tonverkFrameSize` is not one Tonverk accepts.
    public static func write(_ table: Wavetable, preset: OutputPreset, options: OutputOptions = OutputOptions()) throws -> OutputFile {
        try validate(table)
        var job = Job(table: table, preset: preset, options: options)
        return try job.run()
    }

    /// Frame sizes Tonverk accepts in a `_wt<N>` tag: powers of two from 64 to 4,096.
    public static let tonverkFrameSizes = [64, 128, 256, 512, 1024, 2048, 4096]

    static func validate(_ table: Wavetable) throws {
        guard let first = table.frames.first, !first.isEmpty else {
            throw WavetableError(.cannotConvert, "“\(table.name)” has no samples to convert.")
        }
        guard table.frames.allSatisfy({ $0.count == first.count }) else {
            throw WavetableError(.cannotConvert, "The frames of “\(table.name)” are not all the same length, so the table cannot be converted.")
        }
        guard table.frames.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw WavetableError(.cannotConvert, "“\(table.name)” contains values that are not numbers (infinite or NaN), so the table cannot be converted.")
        }
    }

    /// What converting `table` for `preset` will do (``plan(frameSize:frameCount:peak:interpolation:preset:options:)``
    /// from the table's own frame size, frame count, peak, and interpolation).
    public static func plan(for table: Wavetable, preset: OutputPreset, options: OutputOptions = OutputOptions()) -> WritePlan {
        plan(frameSize: table.frameSize, frameCount: table.frameCount, peak: table.peak, interpolation: table.interpolation,
             preset: preset, options: options)
    }

    /// What converting a table of `frameCount` frames of `frameSize` samples, peaking at `peak`
    /// and asking for `interpolation` (nil when its file does not say), will do for `preset` with
    /// `options`: the frame size and count written, how the count changes, whether the PPG waveforms
    /// are added, whether the table is turned down, the interpolation recorded, and the file
    /// extension. ``write(_:preset:options:)`` follows the same plan, so a tool can show it before
    /// converting; only whether a table within ±1 is turned down after its frame size changes
    /// (``WritePlan/Scaling/possible``) waits for the conversion itself.
    public static func plan(frameSize: Int, frameCount: Int, peak: Float, interpolation: Interpolation?,
                            preset: OutputPreset, options: OutputOptions = OutputOptions()) -> WritePlan {
        let sizeOut = self.frameSize(for: preset, source: frameSize, options: options)
        let ppg = preset == .thirdWaveP && options.appendPPGStandardWaves
        // With the PPG standard waveforms, the table itself goes into 60 frames and the four follow.
        let tableCount = ppg ? 60 : self.frameCount(for: preset, source: frameCount)
        // Resizing a cycle, up or down, can raise its peak: band-limiting a square or a saw
        // overshoots at the edges (Gibbs), and a 2,048-sample square shrunk to 128 peaks at
        // about 1.18. So a table within ±1 may be turned down after any change of frame size;
        // a change of frame count or the PPG waveforms cannot raise the peak.
        let scaling: WritePlan.Scaling
        if !preset.scalesToFit { scaling = .none }
        else if peak > 1 { scaling = .certain }
        else { scaling = sizeOut != frameSize ? .possible : .none }
        return WritePlan(preset: preset, frameSizeIn: frameSize, frameSizeOut: sizeOut,
                         frameCountIn: frameCount, frameCountOut: tableCount + (ppg ? 4 : 0),
                         countPolicy: options.frameCountPolicy, addsPPGWaves: ppg,
                         peak: peak, scalesToFit: preset.scalesToFit, scaling: scaling,
                         interpolationRecorded: interpolationRecorded(for: preset, source: interpolation, options: options),
                         fileExtension: preset.fileExtension)
    }

    /// The interpolation `preset`'s file records for a table whose own is `source` (nil when its
    /// file does not say): `options.interpolation`, else `source`, else crossfade; nil when the
    /// format cannot record one. A Tonverk name can say only stepped or smooth, so spectral is
    /// recorded as crossfade there.
    public static func interpolationRecorded(for preset: OutputPreset, source: Interpolation?,
                                             options: OutputOptions = OutputOptions()) -> Interpolation? {
        guard preset.recordsInterpolation else { return nil }
        let asked = options.interpolation ?? source ?? .crossfade
        return preset == .tonverk && asked == .spectral ? .crossfade : asked
    }

    /// One conversion: the frames as they change, and the notes saying how. Every step follows
    /// `plan`, so what the writer does is what ``WavetableWriter/plan(for:preset:options:)`` said.
    private struct Job {
        let table: Wavetable
        let preset: OutputPreset
        let options: OutputOptions
        let plan: WritePlan
        var frames: [[Float]]
        var notes: [String] = []

        init(table: Wavetable, preset: OutputPreset, options: OutputOptions) {
            self.table = table; self.preset = preset; self.options = options; frames = table.frames
            plan = WavetableWriter.plan(for: table, preset: preset, options: options)
        }

        /// The interpolation asked for (the option, else the table's, else crossfade), which the
        /// notes speak of; `plan.interpolationRecorded` is what the file gets.
        var interpolation: Interpolation { options.interpolation ?? table.interpolation ?? .crossfade }

        mutating func run() throws -> OutputFile {
            if preset == .tonverk, let asked = options.tonverkFrameSize, !WavetableWriter.tonverkFrameSizes.contains(asked) {
                throw WavetableError(.cannotConvert, "Tonverk takes frames of 64, 128, 256, 512, 1,024, 2,048, or 4,096 samples, not \(grouped(asked)).")
            }
            // The shared steps, in the plan's order: the frame count and size, the level, the
            // PPG waveforms; then what each destination says and writes.
            reshape()
            if preset == .miniFreak, plan.frameCountIn < 64 {
                let n = plan.frameCountIn
                notes.append("\(n) frame\(n == 1 ? "" : "s"), fewer than the 64 a MiniFreak stores; the count is left at \(n), since how MiniFreak V treats fewer than 64 is not documented.")
            }
            if plan.scalesToFit { scaleToFit() } else { notePeakKept() }
            if plan.addsPPGWaves {
                frames += PPGStandardWaves.frames
                notes.append("The PPG’s four standard waveforms (triangle, narrow pulse, square, and sawtooth) were added at positions 60–63.")
            }
            switch preset {
            case .thirdWaveU:
                noteUnrecordedInterpolation()
                return try thirdWaveFile(kind: .u, chain: Resampling.thirdWaveMipmapChain(frames))
            case .thirdWaveP:
                noteUnrecordedInterpolation()
                return try thirdWaveFile(kind: .p, chain: nil)   // WavetableFile computes the differences
            case .wav2048, .miniFreak, .phasePlant:
                return serumStyleWAV()
            case .tonverk:
                return tonverk()
            case .surge:
                noteUnrecordedInterpolation()
                return OutputFile(fileName: stem() + "." + plan.fileExtension, data: WavetableWriter.Bytes.surge(frames: frames), notes: notes)
            case .waveEdit:
                noteUnrecordedInterpolation()
                let data = WavetableWriter.Bytes.wav(samples: frames.flatMap { $0 }, sampleRate: 44_100, format: .pcm16, clm: nil)
                return OutputFile(fileName: stem() + "." + plan.fileExtension, data: data, notes: notes)
            }
        }

        // MARK: Destinations

        mutating func tonverk() -> OutputFile {
            let stepped = plan.interpolationRecorded == Interpolation.none
            if interpolation == .spectral {
                // Spectral from the options or from the source file: say which. (Notes name
                // where a value came from, never "asked for": Adam, 2026-10-26. The app never
                // passes spectral for Tonverk; the first wording is for other callers.)
                let plays = "Tonverk plays the table as a crossfade (Tonverk’s manual says “smooth”, taken here to mean a crossfade)."
                notes.append(options.interpolation == .spectral
                    ? "A Tonverk file name can mark a table only as stepped (a trailing “r”) or not, so the spectral morph given as the interpolation option is left unmarked: " + plays
                    : "The source file records a spectral morph, which a Tonverk file name cannot mark (only stepped, with a trailing “r”, or not): " + plays)
            }
            noteDefaultInterpolation(prefix: "", result: "so the file name carries no “r” and Tonverk plays the table as a crossfade (Tonverk’s manual says “smooth”, taken here to mean a crossfade)")
            let named = WavetableWriter.Names.fileStem(table.name)
            notes += named.notes
            let untagged = WavetableWriter.Names.removeTonverkTag(named.stem)
            let tag = "_wt\(plan.frameSizeOut)" + (stepped ? "r" : "")
            if let old = untagged.removed {
                notes.append("The name’s own Tonverk tag “\(old)” was replaced by “\(tag)”.")
            }
            let data = WavetableWriter.Bytes.wav(samples: frames.flatMap { $0 }, sampleRate: 48_000, format: .float32, clm: nil)
            return OutputFile(fileName: untagged.stem + tag + "." + plan.fileExtension, data: data, notes: notes)
        }

        mutating func serumStyleWAV() -> OutputFile {
            noteDefaultInterpolation()
            // These presets record the interpolation, so the plan always has one.
            let clm = WavetableWriter.Bytes.clmText(frameSize: plan.frameSizeOut, interpolation: plan.interpolationRecorded ?? .crossfade)
            let data = WavetableWriter.Bytes.wav(samples: frames.flatMap { $0 }, sampleRate: 48_000, format: .float32, clm: clm)
            return OutputFile(fileName: stem() + "." + plan.fileExtension, data: data, notes: notes)
        }

        /// The frames (already 64 of the kind's size) as a `.wt`, laid out by PgdataFormats.
        mutating func thirdWaveFile(kind: WavetableFile.Kind, chain: [Float]?) throws -> OutputFile {
            let named = WavetableWriter.Names.thirdWave(table.name)
            notes += named.notes
            let data = try WavetableFile(kind: kind, name: named.name, frames: frames, mipmapChain: chain).serialized()
            return OutputFile(fileName: stem() + "." + plan.fileExtension, folder: "WAVES", data: data, notes: notes)
        }

        // MARK: Shared steps

        mutating func stem() -> String {
            let named = WavetableWriter.Names.fileStem(table.name)
            notes += named.notes
            return named.stem
        }

        /// Why the destination's frame count is what it is, completing "… frames" in the note.
        var countReason: String {
            switch preset {
            case .thirdWaveU: return "a 3rd Wave U table has exactly 64"
            case .thirdWaveP: return plan.addsPPGWaves ? "the PPG’s standard waveforms take the last 4 of 64" : "a 3rd Wave P table has exactly 64"
            case .wav2048: return "Serum, Vital, and Pigments take at most 256"
            case .miniFreak: return "a MiniFreak stores 64"
            case .phasePlant: return "Phase Plant’s documentation asks for exactly 256"
            case .tonverk: return "Tonverk takes at most 64"
            case .surge: return "Surge takes at most 512"
            case .waveEdit: return "a WaveEdit bank has exactly 64"
            }
        }

        /// Brings the frames to the plan's frame size and to the frames the table itself goes
        /// into (`plan.tableFrameCount`), noting each change.
        mutating func reshape() {
            let n = frames.count
            let target = plan.tableFrameCount
            let size = plan.frameSizeOut
            // Fewer frames first (less to resample), more frames after.
            if target < n { changeCount(to: target, reason: countReason) }
            let from = frames.first?.count ?? 0
            if from != size {
                frames = frames.map { Resampling.resizeCycle($0, to: size) }
                if size > from {
                    notes.append("Resized from \(grouped(from)) to \(grouped(size)) samples per frame; the waveform is unchanged (band-limited, no harmonics added).")
                } else {
                    notes.append("Resized from \(grouped(from)) to \(grouped(size)) samples per frame; the \(ordinal(size / 2 + 1)) harmonic and above, which frames of \(grouped(size)) samples can’t hold, are dropped.")
                }
            }
            if target > n { changeCount(to: target, reason: countReason) }
        }

        mutating func changeCount(to m: Int, reason: String) {
            let n = frames.count
            frames = Resampling.changeFrameCount(frames, to: m, policy: options.frameCountPolicy)
            let how: String
            switch (options.frameCountPolicy, m < n) {
            case (.pickEvenly, true): how = "keeping evenly spaced original frames, the first and last among them"
            case (.pickEvenly, false): how = "repeating frames at evenly spaced positions (no new frames)"
            case (.interpolate, _): how = "crossfading neighboring frames at evenly spaced positions, keeping the first and last"
            }
            notes.append("Frame count changed from \(grouped(n)) to \(grouped(m)) (\(reason) frames), \(how).")
        }

        /// For a destination that cannot hold samples beyond ±1 (`plan.scalesToFit`): scales the
        /// frames down so the peak is 1 when, after resizing, it is above 1 (resizing either way
        /// can overshoot). This is the one decision the plan cannot make beforehand
        /// (``WritePlan/Scaling/possible``).
        mutating func scaleToFit() {
            let peak = currentPeak
            guard peak > 1 else { return }
            let g = 1 / peak
            frames = frames.map { $0.map { $0 * g } }
            let reason = preset.isThirdWave ? "the 3rd Wave’s own tables stay within ±1" : "16-bit samples cannot go beyond full scale"
            // "Attenuated", the audio word, rather than "turned down" (Adam, 2026-10-26). A peak
            // just over 1 (a resized factory table, say) is attenuated by less than 0.05 dB,
            // which would read as "0.0 dB".
            let dB = decimal(-20 * log10(Double(g)), 1)
            let amount = dB == "0.0" ? "by less than 0.1 dB" : "by \(dB) dB"
            notes.append("Attenuated \(amount) to fit within ±1 (the peak was \(Wavetable.peakText(peak))): \(reason).")
        }

        mutating func notePeakKept() {
            let peak = currentPeak
            guard peak > 1 else { return }
            notes.append("Peak \(Wavetable.peakText(peak)) kept, over full scale (±1): unless the synth attenuates the table, the loudest parts may clip, which adds a hard, buzzy edge.")
        }

        /// For destinations that record the interpolation: says that the file records a
        /// crossfade (or, for Tonverk, no stepped mark) because the source file doesn't specify
        /// the interpolation and no other choice was made. `prefix` opens the note (a sentence
        /// and a space, or nothing); `result` closes it, after "so".
        mutating func noteDefaultInterpolation(prefix: String = "This format records whether and how a synth interpolates between frames. ",
                                               result: String = "so crossfade is saved") {
            if options.interpolation == nil && table.interpolation == nil {
                notes.append("\(prefix)The source file says nothing about interpolation, and none was selected in the Interpolation setting, \(result).")
            }
        }

        /// For destinations whose files can't record the interpolation: says so when the
        /// options or the source file give one, naming which (the app passes none for these
        /// destinations, so from the app only the source file's is reported).
        mutating func noteUnrecordedInterpolation() {
            let who = preset.isThirdWave ? "the 3rd Wave" : "the synth"
            func words(_ i: Interpolation) -> String { i == Interpolation.none ? "no interpolation" : i.displayName.lowercased() }
            if let given = options.interpolation {
                notes.append("This format doesn’t store the interpolation method, so the interpolation option (\(words(given))) is not written; \(who) sets how frames blend.")
            } else if let recorded = table.interpolation {
                notes.append("This format doesn’t store the interpolation method, so what the source file records (\(words(recorded))) is not carried over; \(who) sets how frames blend.")
            }
        }

        var currentPeak: Float { frames.reduce(0) { m, f in f.reduce(m) { Swift.max($0, abs($1)) } } }
    }

    /// Whether Surge accepts `n` samples per frame in a `.wt`: a power of two from 2 to 4,096.
    public static func isSurgeFrameSize(_ n: Int) -> Bool { n >= 2 && n <= 4096 && (n & (n - 1)) == 0 }

    /// The frame count `preset` writes for a table of `source` frames: the preset's required
    /// count, else the source's up to its most (``OutputPreset/requiredFrameCount``,
    /// ``OutputPreset/maxFrameCount``). With the PPG waveforms, the table itself goes into 60 frames
    /// instead; see ``plan(frameSize:frameCount:peak:interpolation:preset:options:)``.
    public static func frameCount(for preset: OutputPreset, source: Int) -> Int {
        preset.requiredFrameCount ?? Swift.min(source, preset.maxFrameCount)
    }

    /// The frame size `preset` writes for a table of `source` samples per frame with `options`:
    /// the preset's fixed size; for Tonverk the requested size, else the source's when Tonverk
    /// accepts it, else 2,048; for Surge the source's when it is a power of two up to 4,096, else
    /// 2,048. The writer and any preview of its result both use this.
    public static func frameSize(for preset: OutputPreset, source: Int, options: OutputOptions = OutputOptions()) -> Int {
        switch preset {
        case .tonverk:
            // A requested size Tonverk does not take is not planned for either: `run()` refuses it.
            if let n = options.tonverkFrameSize, tonverkFrameSizes.contains(n) { return n }
            return tonverkFrameSizes.contains(source) ? source : 2048
        case .surge:
            return isSurgeFrameSize(source) ? source : 2048
        default:
            return preset.frameSize ?? source
        }
    }

    /// An integer with thousands separators ("2,048"); see `WavetableReader.grouped`.
    static func grouped(_ n: Int) -> String { WavetableReader.grouped(n) }

    static func decimal(_ v: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", v).replacingOccurrences(of: "-", with: "−")
    }

    /// "1st", "2nd", "3rd", "4th", "11th", "64th", …
    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return grouped(n) + suffix
    }
}

/// What converting a table for a destination will do, from the table's frame size, frame count,
/// peak, and interpolation alone (``WavetableWriter/plan(for:preset:options:)``). The writer
/// follows it step by step, so a tool can show it before converting; the writer's own notes,
/// afterward, say what was done.
public struct WritePlan: Equatable, Sendable {
    /// Whether the table is turned down to fit the destination.
    public enum Scaling: Equatable, Sendable {
        /// Not turned down: the destination keeps samples beyond ±1 as they are, or the peak is
        /// within ±1 and the frame size does not change.
        case none
        /// The peak is within ±1, but the frame size changes, which can raise the peak a little
        /// (new samples between the originals, or the overshoot of band-limiting a sharp edge);
        /// the writer then turns the table down for a destination that cannot hold more than ±1.
        /// Only converting settles it.
        case possible
        /// The peak is above 1 and the destination cannot hold it: turned down.
        case certain
    }

    /// The destination.
    public var preset: OutputPreset
    /// Samples per frame in the source.
    public var frameSizeIn: Int
    /// Samples per frame written.
    public var frameSizeOut: Int
    /// Frames in the source.
    public var frameCountIn: Int
    /// Frames written (with the PPG waveforms, the 60 the table goes into plus the 4 waveforms).
    public var frameCountOut: Int
    /// How the frame count is changed, when it is.
    public var countPolicy: FrameCountPolicy
    /// Whether the PPG's four standard waveforms are added at 60–63.
    public var addsPPGWaves: Bool
    /// The source's peak.
    public var peak: Float
    /// Whether the destination turns a table over full scale down to fit
    /// (``OutputPreset/scalesToFit``).
    public var scalesToFit: Bool
    /// Whether this table is turned down.
    public var scaling: Scaling
    /// The interpolation as the file will record it; nil when the format cannot record it.
    public var interpolationRecorded: Interpolation?
    /// The extension of the file written, without the dot.
    public var fileExtension: String

    /// Whether the frame size changes.
    public var resizes: Bool { frameSizeIn != frameSizeOut }
    /// Whether the frame size grows (nil when it does not change).
    public var frameSizeGrows: Bool? { resizes ? frameSizeOut > frameSizeIn : nil }
    /// The frames the table itself goes into (60 with the PPG waveforms, else `frameCountOut`).
    public var tableFrameCount: Int { addsPPGWaves ? frameCountOut - 4 : frameCountOut }
    /// Whether the table's frame count changes.
    public var changesCount: Bool { tableFrameCount != frameCountIn }
    /// Whether the table gets more frames (nil when the count does not change).
    public var frameCountGrows: Bool? { changesCount ? tableFrameCount > frameCountIn : nil }
    /// Whether the table gets more frames by repeating its own (`.pickEvenly` with more frames
    /// wanted), so that runs of identical frames follow one another in the file.
    public var repeatsFrames: Bool { frameCountGrows == true && countPolicy == .pickEvenly }
    /// Whether the table is turned down to fit (`scaling` is `.certain`).
    public var scaledToFit: Bool { scaling == .certain }
    /// Whether the table may be turned down even though its own peak is within ±1 (`scaling`
    /// is `.possible`).
    public var mayScaleToFit: Bool { scaling == .possible }
    /// Whether the source's peak is above 1 but kept (32-bit destinations).
    public var peakKept: Bool { peak > 1 && !scalesToFit }
}

public extension OutputPreset {
    /// The name used in reports (e.g., "Serum, Vital, Pigments"); the destination list shows
    /// `shortTitle` with `specLine` under it.
    var title: String {
        switch self {
        case .thirdWaveU: return "3rd Wave U table"
        case .thirdWaveP: return "3rd Wave P table"
        case .wav2048: return "Serum, Vital, Pigments"
        case .miniFreak: return "MiniFreak V"
        case .tonverk: return "Elektron Tonverk"
        case .phasePlant: return "Phase Plant"
        case .surge: return "Surge XT"
        case .waveEdit: return "WaveEdit, E370"
        }
    }

    /// The apps or hardware the preset has been tested in (empty while it rests on its sources
    /// alone). Nothing has been tested with this app yet, so every preset's list is empty.
    var testedIn: [String] { [] }

    /// The sources the preset follows, each with its publisher, for the tooltip (e.g., "Elektron,
    /// Tonverk User Manual OS 1.4.1, §5.2.5"). docs/WAVETABLES.md gives the links.
    var basis: String {
        switch self {
        case .thirdWaveU:
            return "Groove Synthesis, 3rd Wave User Manual v1.9 (Wave Maker) and MIDI CC + SysEx Spec v2a; the factory .wt files; tests on the 3rd Wave (FORMATS.md 5.1)"
        case .thirdWaveP:
            return "Groove Synthesis, 3rd Wave User Manual v1.9; the factory .wt files (FORMATS.md 5.1)"
        case .wav2048:
            return "Xfer Records, Serum 2 User Guide, p. 38; Vital Audio, Vital’s public source code; Arturia, Pigments User Manual 7.0, §8.12"
        case .miniFreak:
            return "Arturia, MiniFreak V User Manual 5.1.0, pp. 30–31"
        case .tonverk:
            return "Elektron, Tonverk User Manual OS 1.4.1, §5.2.5, pp. 19–20"
        case .phasePlant:
            return "Kilohearts, Phase Plant manual (Wavetable Oscillator) and its Wavetables page"
        case .surge:
            return "Surge Synth Team, Surge XT source code (WT fileformat.txt, Wavetable.h)"
        case .waveEdit:
            return "Synthesis Technology, E370 Quick Start 1.4; WaveEdit’s source code (WaveEdit.hpp, bank.cpp)"
        }
    }

    /// Where the preset's sources are incomplete or unconfirmed, what that leaves open (shown
    /// with the destination's sources; the Wavetables page warns in the open only when the
    /// tables to convert bring one of these about, see `ConvertPlan.caveat(for:)`); nil when the
    /// sources settle its behavior. From the open questions in docs/WAVETABLES.md.
    var caveat: String? {
        switch self {
        case .wav2048:
            return "Vital’s behavior is taken from its public source code; the current release may differ. Pigments reads no metadata, so the interpolation saved in the file does not reach it."
        case .miniFreak:
            return "How MiniFreak V reduces 2,048-sample frames to 512, and how it treats fewer than 64 frames, is not documented."
        case .phasePlant:
            return "Kilohearts documents exactly 256 frames; whether a shorter table loads is untested, so 256 are always written."
        case .thirdWaveU, .thirdWaveP, .tonverk, .surge, .waveEdit:
            return nil
        }
    }

    /// Samples per frame the preset writes, when fixed; nil for Tonverk (from the source, or
    /// `OutputOptions.tonverkFrameSize`) and Surge (the source's when it is a power of two from 2
    /// to 4,096, otherwise 2,048).
    var frameSize: Int? {
        switch self {
        case .thirdWaveU: return 1024
        case .thirdWaveP: return 128
        case .wav2048, .miniFreak, .phasePlant: return 2048
        case .waveEdit: return 256
        case .tonverk, .surge: return nil
        }
    }

    /// The most frames the preset writes; a larger table is reduced by the frame-count policy.
    var maxFrameCount: Int {
        switch self {
        case .thirdWaveU, .thirdWaveP, .miniFreak, .tonverk, .waveEdit: return 64
        case .wav2048, .phasePlant: return 256
        case .surge: return 512
        }
    }

    /// The exact number of frames the preset writes, when fixed (a smaller table is expanded by
    /// the frame-count policy); nil when fewer than ``maxFrameCount`` are written as they are.
    var requiredFrameCount: Int? {
        switch self {
        case .thirdWaveU, .thirdWaveP, .waveEdit: return 64
        case .phasePlant: return 256
        case .wav2048, .miniFreak, .tonverk, .surge: return nil
        }
    }

    /// Whether the preset writes a 3rd Wave `.wt` (output that can go to the Pack page).
    var isThirdWave: Bool { self == .thirdWaveU || self == .thirdWaveP }

    /// Whether the preset turns a table over full scale down to fit: the 3rd Wave's own tables
    /// stay within ±1, and 16-bit samples cannot go beyond it. The 32-bit float destinations
    /// keep the peak as it is.
    var scalesToFit: Bool { isThirdWave || self == .waveEdit }

    /// The extension of the files the preset writes, without the dot: "wt" or "wav".
    var fileExtension: String {
        switch self {
        case .thirdWaveU, .thirdWaveP, .surge: return "wt"
        case .wav2048, .miniFreak, .tonverk, .phasePlant, .waveEdit: return "wav"
        }
    }
}
