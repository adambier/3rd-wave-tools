import Foundation

// What the Convert page shows about each destination: a short title, its size in one line, the
// group it belongs to, why it is a separate destination, and what its files can record. The
// facts the writer works from (frame size, frame count, file extension) are in Writing.swift.

public extension OutputPreset {
    /// The two groups the destinations are listed under.
    enum Group: String, Equatable, Sendable, CaseIterable {
        /// The 3rd Wave's own `.wt` tables.
        case thirdWave
        /// Every other synth.
        case otherSynths

        /// The heading the group is listed under.
        public var title: String {
            switch self {
            case .thirdWave: return "3rd Wave"
            case .otherSynths: return "Other synths"
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

    /// The size and file kind in one line ("64 × 1,024 · .wt", "up to 256 × 2,048 · WAV").
    var specLine: String {
        switch self {
        case .thirdWaveU: return "64 × 1,024 · .wt"
        case .thirdWaveP: return "64 × 128 · .wt"
        case .wav2048: return "up to 256 × 2,048 · WAV"
        case .miniFreak: return "up to 64 × 2,048 · WAV"
        case .tonverk: return "up to 64 frames · WAV, size in name"
        case .phasePlant: return "256 × 2,048 · WAV"
        case .surge: return "up to 512 frames · Surge .wt"
        case .waveEdit: return "64 × 256 · 16-bit WAV"
        }
    }

    /// One line on why the preset is a destination of its own.
    var distinction: String {
        switch self {
        case .thirdWaveU:
            return "The 3rd Wave's U set: 64 waves of 1,024, plus the smaller copies every U .wt carries."
        case .thirdWaveP:
            return "The 3rd Wave's PPG-style P set: 64 waves of 128."
        case .wav2048:
            return "The common 2,048-sample WAV; records how to move between frames for Serum and Vital."
        case .miniFreak:
            return "The same WAV, cut to the 64 frames a MiniFreak keeps. Convert does the cutting, since MiniFreak V doesn't say how it would."
        case .tonverk:
            return "Up to 64 frames; Tonverk reads the frame size and stepping from the file name."
        case .phasePlant:
            return "Exactly 256 frames, as Phase Plant's documentation asks; shorter tables are filled out."
        case .surge:
            return "Surge's own .wt; keeps the source's frame size."
        case .waveEdit:
            return "16-bit, 64 waves of 256: the bank format the E370 and E352 read."
        }
    }

    /// Whether the preset's files record how to move between frames: a `clm ` chunk (Serum,
    /// Vital, Pigments, MiniFreak V, Phase Plant) or Tonverk's file name.
    var recordsInterpolation: Bool {
        switch self {
        case .wav2048, .miniFreak, .phasePlant, .tonverk: return true
        case .thirdWaveU, .thirdWaveP, .surge, .waveEdit: return false
        }
    }
}

public extension Interpolation {
    /// The word shown for the value: "Steps", "Crossfade", or "Spectral" (never the raw name).
    var displayName: String {
        switch self {
        case .none: return "Steps"
        case .crossfade: return "Crossfade"
        case .spectral: return "Spectral"
        }
    }

    /// The word shown for an optional value: its `displayName`, or "Not stated" for nil.
    static func displayName(_ value: Interpolation?) -> String { value?.displayName ?? "Not stated" }
}
