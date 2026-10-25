import Foundation
#if canImport(PgdataFormats)
import PgdataFormats   // SwiftPM build; absent in the app's single-module swiftc build
#endif

/// Writes a wavetable for a destination.
public enum WavetableWriter {
    /// Converts `table` to `preset`'s format: frame size, frame count, sample format, metadata,
    /// and file name.
    ///
    /// The result's `notes` say every change made (frame size resampled, frame count changed and
    /// how, scaled, name shortened or adjusted). Frame sizes change by band-limited resampling
    /// (``Resampling/resizeCycle(_:to:)``); frame counts by `options.frameCountPolicy`
    /// (``Resampling/changeFrameCount(_:to:policy:)``). WAVs are written at 48 kHz, except
    /// WaveEdit's 44.1 kHz. The interpolation recorded, where the format can record one, is
    /// `options.interpolation`, else the table's, else crossfade.
    ///
    /// - Throws: ``WavetableError`` when the table is empty, its frames differ in length, a sample
    ///   is not a finite number, or `options.tonverkFrameSize` is not one Tonverk accepts.
    public static func write(_ table: Wavetable, preset: OutputPreset, options: OutputOptions = OutputOptions()) throws -> OutputFile {
        try validate(table)
        var job = Job(table: table, preset: preset, options: options)
        return try job.run()
    }

    /// Frame sizes Tonverk accepts in a `_wt<N>` tag.
    static let tonverkFrameSizes = [64, 128, 256, 512, 1024, 2048, 4096]

    static func validate(_ table: Wavetable) throws {
        guard let first = table.frames.first, !first.isEmpty else {
            throw WavetableError("“\(table.name)” has no samples to convert.")
        }
        guard table.frames.allSatisfy({ $0.count == first.count }) else {
            throw WavetableError("The frames of “\(table.name)” are not all the same length, so it cannot be converted.")
        }
        guard table.frames.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw WavetableError("“\(table.name)” contains values that are not numbers (infinite or NaN), so it cannot be converted.")
        }
    }

    /// One conversion: the frames as they change, and the notes saying how.
    private struct Job {
        let table: Wavetable
        let preset: OutputPreset
        let options: OutputOptions
        var frames: [[Float]]
        var notes: [String] = []

        init(table: Wavetable, preset: OutputPreset, options: OutputOptions) {
            self.table = table; self.preset = preset; self.options = options; frames = table.frames
        }

        var interpolation: Interpolation { options.interpolation ?? table.interpolation ?? .crossfade }

        mutating func run() throws -> OutputFile {
            switch preset {
            case .thirdWaveU: return try thirdWaveU()
            case .thirdWaveP: return try thirdWaveP()
            case .wav2048: return wav2048()
            case .miniFreak: return miniFreak()
            case .tonverk: return try tonverk()
            case .phasePlant: return phasePlant()
            case .surge: return surge()
            case .waveEdit: return waveEdit()
            }
        }

        // MARK: Destinations

        mutating func thirdWaveU() throws -> OutputFile {
            reshape(size: 1024, count: 64, exact: true, reason: "a 3rd Wave U table has exactly 64")
            scaleToFit(reason: "the 3rd Wave's own tables stay within ±1")
            noteUnrecordedInterpolation()
            return try thirdWaveFile(kind: .u, chain: Resampling.thirdWaveMipmapChain(frames))
        }

        mutating func thirdWaveP() throws -> OutputFile {
            if options.appendPPGStandardWaves {
                reshape(size: 128, count: 60, exact: true,
                        reason: "the PPG's standard waves take the last 4 of 64")
                scaleToFit(reason: "the 3rd Wave's own tables stay within ±1")
                frames += PPGStandardWaves.frames
                notes.append("The PPG's four standard waves (triangle, narrow pulse, square, and sawtooth) were added at positions 60–63.")
            } else {
                reshape(size: 128, count: 64, exact: true, reason: "a 3rd Wave P table has exactly 64")
                scaleToFit(reason: "the 3rd Wave's own tables stay within ±1")
            }
            noteUnrecordedInterpolation()
            return try thirdWaveFile(kind: .p, chain: nil)   // WavetableFile computes the differences
        }

        mutating func wav2048() -> OutputFile {
            reshape(size: 2048, count: 256, exact: false, reason: "Serum and Pigments take at most 256")
            return serumStyleWAV()
        }

        mutating func miniFreak() -> OutputFile {
            let n = frames.count
            reshape(size: 2048, count: 64, exact: false, reason: "a MiniFreak stores 64")
            if n < 64 {
                notes.append("\(n) frame\(n == 1 ? "" : "s"), fewer than the 64 a MiniFreak stores; left as it is, since how MiniFreak V treats fewer than 64 is not documented.")
            }
            return serumStyleWAV()
        }

        mutating func phasePlant() -> OutputFile {
            reshape(size: 2048, count: 256, exact: true, reason: "Phase Plant's documentation asks for exactly 256")
            return serumStyleWAV()
        }

        mutating func tonverk() throws -> OutputFile {
            let size: Int
            if let asked = options.tonverkFrameSize {
                guard WavetableWriter.tonverkFrameSizes.contains(asked) else {
                    throw WavetableError("Tonverk takes frames of 64, 128, 256, 512, 1,024, 2,048, or 4,096 samples, not \(grouped(asked)).")
                }
                size = asked
            } else if WavetableWriter.tonverkFrameSizes.contains(table.frameSize) {
                size = table.frameSize
            } else {
                size = 2048
            }
            reshape(size: size, count: 64, exact: false, reason: "Tonverk takes at most 64")
            notePeakKept()
            let stepped = interpolation == .none
            if interpolation == .spectral {
                notes.append("Tonverk has no spectral morph, so the file is marked smooth.")
            }
            noteDefaultInterpolation(as: "marked as smooth")
            let named = WavetableWriter.Names.fileStem(table.name)
            notes += named.notes
            let untagged = WavetableWriter.Names.removeTonverkTag(named.stem)
            let tag = "_wt\(size)" + (stepped ? "r" : "")
            if let old = untagged.removed {
                notes.append("The name's own Tonverk tag “\(old)” was replaced by “\(tag)”.")
            }
            let data = WavetableWriter.Bytes.wav(samples: frames.flatMap { $0 }, sampleRate: 48_000, format: .float32, clm: nil)
            return OutputFile(fileName: untagged.stem + tag + ".wav", data: data, notes: notes)
        }

        mutating func surge() -> OutputFile {
            let n = table.frameSize
            let size = WavetableWriter.isSurgeFrameSize(n) ? n : 2048
            reshape(size: size, count: 512, exact: false, reason: "Surge takes at most 512")
            notePeakKept()
            noteUnrecordedInterpolation()
            return OutputFile(fileName: stem() + ".wt", data: WavetableWriter.Bytes.surge(frames: frames), notes: notes)
        }

        mutating func waveEdit() -> OutputFile {
            reshape(size: 256, count: 64, exact: true, reason: "a WaveEdit bank has exactly 64")
            scaleToFit(reason: "16-bit samples cannot go beyond full scale")
            noteUnrecordedInterpolation()
            let data = WavetableWriter.Bytes.wav(samples: frames.flatMap { $0 }, sampleRate: 44_100, format: .pcm16, clm: nil)
            return OutputFile(fileName: stem() + ".wav", data: data, notes: notes)
        }

        // MARK: Shared steps

        mutating func serumStyleWAV() -> OutputFile {
            notePeakKept()
            noteDefaultInterpolation()
            let clm = WavetableWriter.Bytes.clmText(frameSize: 2048, interpolation: interpolation)
            let data = WavetableWriter.Bytes.wav(samples: frames.flatMap { $0 }, sampleRate: 48_000, format: .float32, clm: clm)
            return OutputFile(fileName: stem() + ".wav", data: data, notes: notes)
        }

        /// The frames (already 64 of the kind's size) as a `.wt`, laid out by PgdataFormats.
        mutating func thirdWaveFile(kind: WavetableFile.Kind, chain: [Float]?) throws -> OutputFile {
            let named = WavetableWriter.Names.thirdWave(table.name)
            notes += named.notes
            let data = try WavetableFile(kind: kind, name: named.name, frames: frames, mipmapChain: chain).serialized()
            return OutputFile(fileName: stem() + ".wt", folder: "WAVES", data: data, notes: notes)
        }

        mutating func stem() -> String {
            let named = WavetableWriter.Names.fileStem(table.name)
            notes += named.notes
            return named.stem
        }

        /// Brings the frames to `size` samples and to `count` frames (exactly, or at most when
        /// `exact` is false), noting each change. `reason` completes "… frames" for the note.
        mutating func reshape(size: Int, count: Int, exact: Bool, reason: String) {
            let n = frames.count
            let target = exact ? count : Swift.min(n, count)
            // Fewer frames first (less to resample), more frames after.
            if target < n { changeCount(to: target, reason: reason) }
            let from = frames.first?.count ?? 0
            if from != size {
                frames = frames.map { Resampling.resizeCycle($0, to: size) }
                if size > from {
                    notes.append("Resized from \(grouped(from)) to \(grouped(size)) samples per frame; the waveform is unchanged (band-limited, no harmonics added).")
                } else {
                    notes.append("Resized from \(grouped(from)) to \(grouped(size)) samples per frame; the \(ordinal((size - 1) / 2 + 1)) harmonic and above are dropped, as \(grouped(size)) samples can't hold them.")
                }
            }
            if target > n { changeCount(to: target, reason: reason) }
        }

        mutating func changeCount(to m: Int, reason: String) {
            let n = frames.count
            frames = Resampling.changeFrameCount(frames, to: m, policy: options.frameCountPolicy)
            let how: String
            switch (options.frameCountPolicy, m < n) {
            case (.pickEvenly, true): how = "keeping evenly spaced original frames, the first and last among them"
            case (.pickEvenly, false): how = "repeating frames at evenly spaced positions (no new waves)"
            case (.interpolate, _): how = "crossfading neighbouring frames at evenly spaced positions, keeping the first and last"
            }
            notes.append("Frame count changed from \(grouped(n)) to \(grouped(m)) (\(reason) frames), \(how).")
        }

        /// Scales the frames down so the peak is 1 when it is above 1.
        mutating func scaleToFit(reason: String) {
            let peak = currentPeak
            guard peak > 1 else { return }
            let g = 1 / peak
            frames = frames.map { $0.map { $0 * g } }
            notes.append("Turned down to fit (peak was \(decimal(Double(peak), 2)), \(decimal(20 * log10(Double(g)), 1)) dB); plays a little quieter: \(reason).")
        }

        mutating func notePeakKept() {
            let peak = currentPeak
            guard peak > 1 else { return }
            notes.append("Peak \(decimal(Double(peak), 2)) kept; the synth may clip it.")
        }

        /// For destinations that record the interpolation: says when crossfade (or
        /// Tonverk's smooth) was chosen because nothing said otherwise.
        mutating func noteDefaultInterpolation(as words: String = "saved as crossfade") {
            if options.interpolation == nil && table.interpolation == nil {
                notes.append("Interpolation \(words); the source doesn't say.")
            }
        }

        /// For destinations whose files can't record the interpolation: says so when
        /// the source or the options asked for one.
        mutating func noteUnrecordedInterpolation() {
            if let asked = options.interpolation ?? table.interpolation {
                notes.append("This format can't store the interpolation (\(asked.displayName.lowercased()) asked for); set it on the destination's oscillator.")
            }
        }

        var currentPeak: Float { frames.reduce(0) { m, f in f.reduce(m) { Swift.max($0, abs($1)) } } }
    }

    /// Whether Surge accepts `n` samples per frame in a `.wt`: a power of two from 2 to 4,096.
    static func isSurgeFrameSize(_ n: Int) -> Bool { n >= 2 && n <= 4096 && (n & (n - 1)) == 0 }

    /// An integer with thousands separators ("2,048"), independent of the locale.
    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out += "," }
            out.append(c)
        }
        return (n < 0 ? "-" : "") + out
    }

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
            return "Groove Synthesis, 3rd Wave User Manual v1.9 (Wave Maker) and MIDI CC + SysEx Spec v2a; the factory .wt files; tests on a 3rd Wave (FORMATS.md 5.1)"
        case .thirdWaveP:
            return "Groove Synthesis, 3rd Wave User Manual v1.9; the factory .wt files (FORMATS.md 5.1)"
        case .wav2048:
            return "Xfer Records, Serum 2 User Guide, p. 38; Vital Audio, Vital's public source code; Arturia, Pigments User Manual 7.0, §8.12"
        case .miniFreak:
            return "Arturia, MiniFreak V User Manual 5.1.0, pp. 30–31"
        case .tonverk:
            return "Elektron, Tonverk User Manual OS 1.4.1, §5.2.5, pp. 19–20"
        case .phasePlant:
            return "Kilohearts, Phase Plant manual (Wavetable Oscillator) and its Wavetables page"
        case .surge:
            return "Surge Synth Team, Surge XT source code (WT fileformat.txt, Wavetable.h)"
        case .waveEdit:
            return "Synthesis Technology, E370 Quick Start 1.4; WaveEdit's source code (WaveEdit.hpp, bank.cpp)"
        }
    }

    /// Where the preset's sources are incomplete or unconfirmed, what that leaves open (shown
    /// with the destination); nil when the sources settle its behaviour. From the open questions
    /// in docs/WAVETABLES.md.
    var caveat: String? {
        switch self {
        case .wav2048:
            return "Vital's behaviour is from its public source code, which the current release may differ from. Pigments reads no metadata, so the interpolation saved in the file doesn't apply to it."
        case .miniFreak:
            return "How MiniFreak V reduces tables to 512 samples and 64 cycles is undocumented; Convert reduces the frame count itself. How it treats fewer than 64 frames is unknown."
        case .phasePlant:
            return "Kilohearts documents exactly 256 frames; whether a shorter table loads is untested, so Convert always writes 256."
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

    /// Whether the preset writes a 3rd Wave `.wt` (output that can go to the Pack tab).
    var isThirdWave: Bool { self == .thirdWaveU || self == .thirdWaveP }

    /// The extension of the files the preset writes, without the dot: "wt" or "wav".
    var fileExtension: String {
        switch self {
        case .thirdWaveU, .thirdWaveP, .surge: return "wt"
        case .wav2048, .miniFreak, .tonverk, .phasePlant, .waveEdit: return "wav"
        }
    }
}
