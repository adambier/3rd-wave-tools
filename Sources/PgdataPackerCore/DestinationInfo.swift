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
        case .tonverk: return "Elektron Tonverk"
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
            return "The 3rd Wave’s main set: 64 waves of 1,024. Choose this for Serum-style and other 2,048-sample tables."
        case .thirdWaveP:
            return "PPG-style: 64 waves of 128. With \u{201C}use upper wavetable\u{201D} off, the 3rd Wave sweeps positions 0–59 only (60–63 are reached by the wave offset); the PPG waves option fills 60–63 the way the PPG-derived factory tables do."
        case .wav2048:
            return "The common 2,048-sample WAV, up to 256 frames; the file records the interpolation, which Serum and Vital read."
        case .miniFreak:
            return "The same WAV, at most 64 frames: what a MiniFreak keeps. Larger tables are cut down to 64 here, before MiniFreak V sees them."
        case .tonverk:
            return "Up to 64 frames; Tonverk reads the frame size and stepping from the file name."
        case .phasePlant:
            return "The same WAV, but exactly 256 frames, as Phase Plant’s documentation asks; a table of any other length is brought to 256."
        case .surge:
            return "Surge’s own .wt; keeps the source’s frame size when it is a power of two up to 4,096 (otherwise 2,048)."
        case .waveEdit:
            return "16-bit, 64 waves of 256: the bank format the E370 and E352 read."
        }
    }
}
