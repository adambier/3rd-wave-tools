import Foundation
#if canImport(WavetableFormats)
import WavetableFormats   // SwiftPM build; absent in the app’s single-module swiftc build
#endif

// What the Wavetables page shows about each destination: the group it is listed under, a short
// title, its size in one line, and why it is a separate destination. This is the app's wording,
// so it lives here rather than in WavetableFormats, whose `OutputPreset` extensions (in
// Writing.swift and PresetInfo.swift) carry the facts the writer works from: frame size, frame
// count, file extension, basis, caveat, and whether the format records the interpolation.

public extension OutputPreset {
    /// The two groups the destinations are listed under.
    enum Group: String, Equatable, Sendable, CaseIterable {
        /// The 3rd Wave's own `.wt` tables.
        case thirdWave
        /// Every other synth.
        case otherSynths

        /// The heading the group is listed under (a group heading, so in title case).
        public var title: String {
            switch self {
            case .thirdWave: return "3rd Wave"
            case .otherSynths: return "Other Synths"
            }
        }

        /// The presets in the group, in the order they are listed.
        public var presets: [OutputPreset] { OutputPreset.allCases.filter { $0.group == self } }
    }

    /// The group the preset is listed under.
    var group: Group { isThirdWave ? .thirdWave : .otherSynths }

    /// The name shown in the destination list ("U table", "Serum, Vital, Pigments").
    var shortTitle: String {
        switch self {
        case .thirdWaveU: return "U table"
        case .thirdWaveP: return "P table"
        case .wav2048: return "Serum, Vital, Pigments"
        case .miniFreak: return "MiniFreak V"
        case .tonverk: return "Tonverk"
        case .phasePlant: return "Phase Plant"
        case .surge: return "Surge XT"
        case .waveEdit: return "WaveEdit, E370"
        }
    }

    /// The size and file kind in one line ("64 × 1,024 · .wt", "up to 256 × 2,048 · .wav"): the
    /// file's extension names the kind, the same way for every destination.
    var specLine: String {
        switch self {
        case .thirdWaveU: return "64 × 1,024 · .wt"
        case .thirdWaveP: return "64 × 128 · .wt"
        case .wav2048: return "up to 256 × 2,048 · .wav"
        case .miniFreak: return "up to 64 × 2,048 · .wav"
        case .tonverk: return "up to 64 frames · .wav, size in name"
        case .phasePlant: return "256 × 2,048 · .wav"
        case .surge: return "up to 512 frames · Surge .wt"
        case .waveEdit: return "64 × 256 · 16-bit .wav"
        }
    }

    /// One line on why the preset is a destination of its own.
    var distinction: String {
        switch self {
        case .thirdWaveU:
            // Wavetable smoothing on by default for a U table: checked on an 8M (FORMATS.md section 5.1).
            return "The 3rd Wave’s main set: 64 frames of 1,024 samples with a mipmap chain, played band-limited and, by default, with wavetable smoothing on (the 3rd Wave blends from frame to frame). Keeps the most of a 2,048-sample table."
        case .thirdWaveP:
            // Wavetable smoothing off by default for a P table: checked on an 8M (FORMATS.md section 5.1).
            return "PPG-style: 64 frames of 128 samples, played as the PPG played wavetables, through the three Wave Flow settings, \u{201C}wavetable smoothing\u{201D} (off by default, so the table steps from frame to frame), \u{201C}waveform smoothing\u{201D}, and \u{201C}use upper wavetable\u{201D}. With \u{201C}use upper wavetable\u{201D} off, the 3rd Wave plays positions 0–59 only. With the setting on, the 3rd Wave plays positions 60–63 as well. \u{201C}Add the PPG\u{2019}s standard waveforms at 60–63\u{201D}, under Options, fills those four positions the way the PPG-derived factory tables do."
        case .wav2048:
            return "The common 2,048-sample WAV, up to 256 frames; the file records the interpolation, which Serum and Vital read."
        case .miniFreak:
            return "The same WAV, at most 64 frames: what a MiniFreak keeps. Larger tables are cut down to 64 frames here, before MiniFreak V reads the file."
        case .tonverk:
            return "Up to 64 frames; Tonverk reads the frame size from the file name. An “r” after the size tag at the end of a name (Name_wt128r.wav) asks Tonverk to play each frame’s samples raw, each sample held until the next, as the PPG played its tables: with a bright, stepped edge on frames of 64 or 128 samples. A 3rd Wave P table, or an input file already named with the “r” suffix, is written with the suffix; any other table is written without. Tonverk blends between frames either way."
        case .phasePlant:
            return "The same WAV, but exactly 256 frames, as Phase Plant’s documentation asks; a table of any other length is brought to 256 frames. Phase Plant 2.4.6 has been observed to load a 64-frame table as well; 256 is the documented count."
        case .surge:
            return "Surge’s own .wt; keeps the source’s frame size when that size is a power of two up to 4,096 (otherwise 2,048)."
        case .waveEdit:
            return "16-bit, 64 frames of 256 samples: the bank format the E370 and E352 read."
        }
    }
}
