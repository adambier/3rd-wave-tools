import Foundation

// Facts about the destinations that the writer's `OutputPreset` extension in Writing.swift
// (frame size, frame count, file extension, basis, caveat) does not carry: whether a format
// records the interpolation, and the words for an interpolation, which the writer's notes use.
// What the Wavetables page says about each destination (group, short title, size line,
// distinction) is the app's wording and lives in PgdataPackerCore's DestinationInfo.swift.

public extension OutputPreset {
    /// Whether the preset's files record the interpolation: a `clm ` chunk (Serum,
    /// Vital, Pigments, MiniFreak V, Phase Plant). A Tonverk file name records none: its `r`
    /// is about the playback of each frame's samples, not the blend between frames, which
    /// Tonverk always makes (tests in Tonverk OS 1.4.1).
    var recordsInterpolation: Bool {
        switch self {
        case .wav2048, .miniFreak, .phasePlant: return true
        case .thirdWaveU, .thirdWaveP, .tonverk, .surge, .waveEdit: return false
        }
    }
}

public extension Interpolation {
    /// The word shown for the value: "None (stepped)", "Crossfade", or "Spectral" (never the raw
    /// name "none" alone).
    var displayName: String {
        switch self {
        case .none: return "None (stepped)"
        case .crossfade: return "Crossfade"
        case .spectral: return "Spectral"
        }
    }

    /// The word shown for an optional value: its `displayName`, or "Not stated" for nil.
    static func displayName(_ value: Interpolation?) -> String { value?.displayName ?? "Not stated" }
}
